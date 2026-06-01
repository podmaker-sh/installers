<#
    install-vault-bridge.ps1 — install podmaker-vault-bridge as a
    Windows service via NSSM.

    Usage (elevated PowerShell):

        $env:PODMAKER_BRIDGE_ID    = "01ksz..."
        $env:PODMAKER_BRIDGE_TOKEN = "pdmb_..."
        $env:PODMAKER_CP_URL      = "https://app.podmaker.sh"
        $env:PODMAKER_UPSTREAM_TYPE = "aws-sm"
        # plus upstream-specific env vars
        .\install-vault-bridge.ps1

    Re-running with a different env updates the service in place.
    Uninstall with:
        .\install-vault-bridge.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$Version = "latest",
    # Required unless -BaseUrl is set. Format: "<org>/<repo>".
    # Reads PODMAKER_BRIDGE_REPO env var by default so the install
    # snippet from the CP can drop it in via the environment.
    [string]$Repo = $env:PODMAKER_BRIDGE_REPO,
    # github | gitea | forgejo | gitlab | bitbucket
    [string]$Provider = $(if ($env:PODMAKER_BRIDGE_PROVIDER) { $env:PODMAKER_BRIDGE_PROVIDER } else { "github" }),
    # Override forge host. Defaults to the provider's public host.
    [string]$Host = $env:PODMAKER_BRIDGE_HOST,
    # Optional full base URL override (mirrors, S3, self-hosted forges).
    [string]$BaseUrl = $env:PODMAKER_BRIDGE_BASE_URL,
    [string]$InstallDir = "$env:ProgramFiles\PodMaker\VaultBridge",
    [string]$ServiceName = "PodMakerVaultBridge",
    [string]$NssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
)

$ErrorActionPreference = "Stop"

function Require-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run from an elevated PowerShell prompt."
    }
}

function Get-Nssm {
    $nssm = Join-Path $InstallDir "nssm.exe"
    if (Test-Path $nssm) { return $nssm }
    $tmpZip = Join-Path $env:TEMP "nssm.zip"
    $tmpExtract = Join-Path $env:TEMP "nssm-extract"
    Write-Host "downloading NSSM from $NssmUrl"
    Invoke-WebRequest -Uri $NssmUrl -OutFile $tmpZip -UseBasicParsing
    if (Test-Path $tmpExtract) { Remove-Item -Recurse -Force $tmpExtract }
    Expand-Archive -Path $tmpZip -DestinationPath $tmpExtract -Force
    $arch = if ([Environment]::Is64BitOperatingSystem) { "win64" } else { "win32" }
    $src = Get-ChildItem -Path $tmpExtract -Recurse -Filter "nssm.exe" |
           Where-Object { $_.FullName -match $arch } |
           Select-Object -First 1
    if (-not $src) { throw "could not find nssm.exe inside the downloaded zip" }
    Copy-Item -Path $src.FullName -Destination $nssm -Force
    return $nssm
}

function Resolve-BaseUrl {
    if ($BaseUrl) { return $BaseUrl.TrimEnd('/') }
    if (-not $Repo) { throw "either -BaseUrl or -Repo must be supplied" }

    $h = $Host
    if (-not $h) {
        $h = switch ($Provider) {
            'github'    { 'github.com' }
            'gitea'     { 'gitea.com' }
            'forgejo'   { 'gitea.com' }
            'gitlab'    { 'gitlab.com' }
            'bitbucket' { 'bitbucket.org' }
            default     { throw "unknown -Provider '$Provider' — set -BaseUrl instead" }
        }
    }
    $isLatest = ($Version -eq "latest")
    switch ($Provider) {
        'github' {
            if ($isLatest) { return "https://$h/$Repo/releases/latest/download" }
            return "https://$h/$Repo/releases/download/bridge-$Version"
        }
        { $_ -in 'gitea','forgejo' } {
            if ($isLatest) { return "https://$h/$Repo/releases/download/latest" }
            return "https://$h/$Repo/releases/download/bridge-$Version"
        }
        'gitlab' {
            if ($isLatest) { return "https://$h/$Repo/-/releases/permalink/latest/downloads" }
            return "https://$h/$Repo/-/releases/bridge-$Version/downloads"
        }
        'bitbucket' { return "https://$h/$Repo/downloads" }
    }
    throw "unsupported provider $Provider"
}

function Get-BridgeBinary {
    $bin = Join-Path $InstallDir "podmaker-vault-bridge.exe"
    $base = Resolve-BaseUrl
    $asset = "podmaker-vault-bridge-windows-amd64.tar.gz"
    Write-Host "downloading $asset from $base"
    $tarball = Join-Path $env:TEMP $asset
    Invoke-WebRequest -Uri "$base/$asset" -OutFile $tarball -UseBasicParsing
    # tar ships with Windows 10+ / Server 2019+
    & tar -xzf $tarball -C $InstallDir
    $expected = Join-Path $InstallDir "podmaker-vault-bridge-windows-amd64.exe"
    if (-not (Test-Path $expected)) {
        throw "tarball did not contain the expected binary"
    }
    Move-Item -Force $expected $bin
    return $bin
}

function Set-ServiceEnvironment {
    param([string]$Nssm, [hashtable]$EnvVars)
    $kv = $EnvVars.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    & $Nssm set $ServiceName AppEnvironmentExtra ($kv -join "`r`n") | Out-Null
}

Require-Admin
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }
$nssm = Join-Path $InstallDir "nssm.exe"

if ($Uninstall) {
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        & $nssm stop   $ServiceName | Out-Null
        & $nssm remove $ServiceName confirm | Out-Null
        Write-Host "service removed: $ServiceName"
    } else {
        Write-Host "service not installed; nothing to do."
    }
    return
}

$required = "PODMAKER_BRIDGE_ID","PODMAKER_BRIDGE_TOKEN","PODMAKER_CP_URL","PODMAKER_UPSTREAM_TYPE"
foreach ($k in $required) {
    if (-not (Get-ChildItem env:$k -ErrorAction SilentlyContinue)) {
        throw "env $k is required"
    }
}

$nssm = Get-Nssm
$bin  = Get-BridgeBinary

$certDir = Join-Path $env:ProgramData "PodMaker\VaultBridge"
if (-not (Test-Path $certDir)) { New-Item -ItemType Directory -Force -Path $certDir | Out-Null }

$envVars = @{}
Get-ChildItem env: | Where-Object { $_.Name -like "PODMAKER_*" } |
    ForEach-Object { $envVars[$_.Name] = $_.Value }
$envVars["PODMAKER_BRIDGE_CERT_DIR"] = $certDir

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "service exists — updating in place"
    & $nssm stop $ServiceName | Out-Null
    & $nssm set  $ServiceName Application $bin | Out-Null
} else {
    & $nssm install $ServiceName $bin | Out-Null
}

& $nssm set $ServiceName AppDirectory  $InstallDir            | Out-Null
& $nssm set $ServiceName DisplayName   "PodMaker Vault Bridge" | Out-Null
& $nssm set $ServiceName Description   "Outbound proxy from this network to the PodMaker control plane." | Out-Null
& $nssm set $ServiceName Start         SERVICE_AUTO_START      | Out-Null
& $nssm set $ServiceName AppStdout     (Join-Path $InstallDir "out.log") | Out-Null
& $nssm set $ServiceName AppStderr     (Join-Path $InstallDir "err.log") | Out-Null
& $nssm set $ServiceName AppRotateFiles 1                       | Out-Null
& $nssm set $ServiceName AppRotateBytes 1048576                 | Out-Null
Set-ServiceEnvironment -Nssm $nssm -EnvVars $envVars

& $nssm start $ServiceName | Out-Null
Write-Host "service installed + started: $ServiceName"
Write-Host "logs: $InstallDir\out.log + err.log"
Write-Host "cert dir: $certDir"
