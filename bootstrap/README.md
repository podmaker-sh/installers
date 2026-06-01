# PodMaker agent bootstrap

Files in this directory are shipped verbatim onto every new
PodMaker-managed server during provisioning, either via cloud-init
or by curl-piping `install.sh` during BYO-SSH adoption.

| File | Purpose |
|------|---------|
| `install.sh` | POSIX-sh installer. Detects arch + init system, verifies the agent tarball checksum, drops the systemd / OpenRC unit, enrolls against step-ca with the one-time token, then starts the service. |
| `podmaker-agent.service` | Systemd unit with the production hardening profile (NoNewPrivileges, ProtectSystem=strict, restricted ReadWritePaths). |
| `cloud-init.yml` | Provider user-data template the orchestrator renders before passing to AWS/Hetzner/DigitalOcean. |

## Required environment

`install.sh` reads the following from its environment:

| Variable | Description |
|----------|-------------|
| `PODMAKER_AGENT_URL` | HTTPS URL of the agent release tarball |
| `PODMAKER_AGENT_SHA256` | Hex SHA-256 of the tarball |
| `PODMAKER_AGENT_ID` | Control-plane-minted server identifier |
| `PODMAKER_GATEWAY_URL` | `wss://gateway.<region>.podmaker.io/v1/agent` |
| `PODMAKER_STEP_CA_URL` | step-ca base URL |
| `PODMAKER_STEP_CA_FINGERPRINT` | `sha256:<base64>` of the step-ca root |

The one-time enrollment token is read from
`/var/lib/podmaker/enrollment` rather than the env — cloud-init
drops it there as a `write_files` entry so it never appears in
`/var/log/cloud-init-output.log` (the env block is logged whole).

## Supported targets

- Debian / Ubuntu (systemd)
- RHEL / Rocky / Alma / Fedora / CentOS Stream (systemd)
- openSUSE / SLES (systemd)
- Arch (systemd)
- Alpine (OpenRC)

x86_64 and arm64. Other arches abort early with exit code 1.

## Safety properties

- Refuses to run without every required env variable.
- Refuses to install a tarball whose SHA-256 doesn't match the
  caller-provided expected value.
- Shreds `/var/lib/podmaker/enrollment` after a successful enroll
  so the one-time token cannot be replayed if the disk is later
  cloned.
- systemd unit pins NoNewPrivileges / ProtectSystem=strict and only
  whitelists the three PodMaker state directories as writable.
- Exit codes are distinct (`1` env, `2` download/checksum,
  `3` install/systemd, `4` enroll) so CI / smoke tests can branch.
