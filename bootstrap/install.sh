#!/bin/sh
# PodMaker agent installer.
#
# Designed to be invoked by cloud-init (Hetzner / DigitalOcean / AWS
# user-data) or piped from curl during BYO-SSH adoption:
#
#   curl -fsSL https://install.podmaker.sh/agent.sh \
#     | PODMAKER_AGENT_URL=… PODMAKER_AGENT_ID=… sh
#
# Required environment:
#   PODMAKER_AGENT_URL              Tar.gz of the agent release for this arch.
#   PODMAKER_AGENT_SHA256           SHA-256 of the tarball (hex).
#   PODMAKER_AGENT_ID               Server identifier minted by the control plane.
#   PODMAKER_GATEWAY_URL            wss://… of the regional agent-gateway.
#   PODMAKER_STEP_CA_URL            https://… of step-ca.
#   PODMAKER_STEP_CA_FINGERPRINT    sha256:base64 of the step-ca root.
#
# The enrollment one-time token must already be present at
# /var/lib/podmaker/enrollment as a PODMAKER_ENROLLMENT_TOKEN=…
# line. Cloud-init writes it via the write_files block the
# orchestrator's provider adapters inject (see conv.go in each
# adapter).
#
# Exit codes:
#   0  success
#   1  missing required env
#   2  download / checksum failed
#   3  install / systemd failed
#   4  enrollment failed

set -eu

log()  { printf '[podmaker-install] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit "${2:-1}"; }

# ---------------------------------------------------------------------------
# Phase 1: validate environment.
# ---------------------------------------------------------------------------

require() {
    name="$1"
    val=$(eval "printf '%s' \"\${$name:-}\"")
    if [ -z "$val" ]; then
        fail "missing env: $name"
    fi
}

require PODMAKER_AGENT_URL
require PODMAKER_AGENT_ID
require PODMAKER_GATEWAY_URL
require PODMAKER_STEP_CA_URL

# SHA256 + step-ca fingerprint are mandatory in production; dev /
# bootstrap installs running before a release is published can opt out
# by setting PODMAKER_AGENT_ALLOW_UNVERIFIED=1.
if [ -z "${PODMAKER_AGENT_SHA256:-}" ]; then
    if [ "${PODMAKER_AGENT_ALLOW_UNVERIFIED:-0}" = "1" ]; then
        log "WARNING: PODMAKER_AGENT_SHA256 empty; skipping checksum verification"
    else
        fail "missing env: PODMAKER_AGENT_SHA256 (set PODMAKER_AGENT_ALLOW_UNVERIFIED=1 to bypass for dev)"
    fi
fi
if [ -z "${PODMAKER_STEP_CA_FINGERPRINT:-}" ]; then
    if [ "${PODMAKER_AGENT_ALLOW_UNVERIFIED:-0}" = "1" ]; then
        log "WARNING: PODMAKER_STEP_CA_FINGERPRINT empty; enrollment will run against an unverified CA"
    else
        fail "missing env: PODMAKER_STEP_CA_FINGERPRINT (set PODMAKER_AGENT_ALLOW_UNVERIFIED=1 to bypass for dev)"
    fi
fi

ENROLL_FILE=/var/lib/podmaker/enrollment
if [ ! -r "$ENROLL_FILE" ]; then
    fail "enrollment token file missing: $ENROLL_FILE"
fi

# ---------------------------------------------------------------------------
# Phase 2: detect platform.
# ---------------------------------------------------------------------------

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)   AGENT_ARCH=amd64 ;;
    aarch64|arm64)  AGENT_ARCH=arm64 ;;
    *)              fail "unsupported architecture: $ARCH" ;;
esac

OS_FAMILY=unknown
INIT_SYSTEM=unknown

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}${ID_LIKE:+ }${ID_LIKE:-}" in
        *debian*|*ubuntu*)      OS_FAMILY=debian ;;
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*)  OS_FAMILY=rhel ;;
        *alpine*)               OS_FAMILY=alpine ;;
        *suse*|*opensuse*)      OS_FAMILY=suse ;;
        *arch*)                 OS_FAMILY=arch ;;
    esac
fi

if [ -d /run/systemd/system ]; then
    INIT_SYSTEM=systemd
elif command -v rc-update >/dev/null 2>&1; then
    INIT_SYSTEM=openrc
fi

log "detected: arch=$AGENT_ARCH os=$OS_FAMILY init=$INIT_SYSTEM"

# ---------------------------------------------------------------------------
# Phase 3: download agent binary, verify checksum, extract.
# ---------------------------------------------------------------------------

INSTALL_DIR=/usr/local/lib/podmaker
CONF_DIR=/etc/podmaker/agent
STATE_DIR=/var/lib/podmaker
BIN_PATH=/usr/local/bin/podmaker-agent

mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$STATE_DIR"
chmod 0700 "$CONF_DIR"

TMP_TAR=$(mktemp /tmp/podmaker-agent.XXXXXX.tar.gz)
trap 'rm -f "$TMP_TAR"' EXIT

if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl -fsSL --proto =https --tlsv1.2"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget -qO-"
else
    fail "neither curl nor wget available" 2
fi

log "downloading agent from $PODMAKER_AGENT_URL"
# shellcheck disable=SC2086
$DOWNLOADER "$PODMAKER_AGENT_URL" > "$TMP_TAR" || fail "agent download failed" 2

if [ -n "${PODMAKER_AGENT_SHA256:-}" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL=$(sha256sum "$TMP_TAR" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        ACTUAL=$(shasum -a 256 "$TMP_TAR" | awk '{print $1}')
    else
        fail "no sha256 tool (sha256sum / shasum) available" 2
    fi
    EXPECTED=$(printf '%s' "$PODMAKER_AGENT_SHA256" | tr 'A-F' 'a-f')
    ACTUAL=$(printf '%s' "$ACTUAL" | tr 'A-F' 'a-f')
    if [ "$ACTUAL" != "$EXPECTED" ]; then
        fail "checksum mismatch: expected $EXPECTED got $ACTUAL" 2
    fi
    log "checksum OK"
else
    log "WARNING: skipping checksum (PODMAKER_AGENT_ALLOW_UNVERIFIED=1)"
fi

if ! tar -xzf "$TMP_TAR" -C "$INSTALL_DIR"; then
    fail "extract failed" 2
fi

if [ ! -x "$INSTALL_DIR/podmaker-agent" ]; then
    fail "tarball missing podmaker-agent binary" 2
fi

install -m 0755 "$INSTALL_DIR/podmaker-agent" "$BIN_PATH"

# ---------------------------------------------------------------------------
# Phase 4: write environment file consumed by the init script.
# ---------------------------------------------------------------------------

ENV_FILE="$CONF_DIR/agent.env"
umask 077
cat >"$ENV_FILE" <<EOF
PODMAKER_AGENT_ID=$PODMAKER_AGENT_ID
PODMAKER_GATEWAY_URL=$PODMAKER_GATEWAY_URL
PODMAKER_STEP_CA_URL=$PODMAKER_STEP_CA_URL
PODMAKER_STEP_CA_FINGERPRINT=$PODMAKER_STEP_CA_FINGERPRINT
PODMAKER_CONFIG_DIR=$CONF_DIR
EOF
chmod 0600 "$ENV_FILE"

# ---------------------------------------------------------------------------
# Phase 5: install init unit + reload.
# ---------------------------------------------------------------------------

case "$INIT_SYSTEM" in
    systemd)
        SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        UNIT_SRC="$SCRIPT_DIR/podmaker-agent.service"
        if [ -f "$UNIT_SRC" ]; then
            install -m 0644 "$UNIT_SRC" /etc/systemd/system/podmaker-agent.service
        else
            cat >/etc/systemd/system/podmaker-agent.service <<'EOF'
[Unit]
Description=PodMaker per-server agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/podmaker/agent/agent.env
ExecStart=/usr/local/bin/podmaker-agent run
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/podmaker /var/lib/podmaker
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
        fi
        systemctl daemon-reload
        ;;

    openrc)
        cat >/etc/init.d/podmaker-agent <<'EOF'
#!/sbin/openrc-run
command="/usr/local/bin/podmaker-agent"
command_args="run"
command_user="root"
command_background="yes"
pidfile="/run/podmaker-agent.pid"
output_log="/var/log/podmaker-agent.log"
error_log="/var/log/podmaker-agent.log"

depend() {
    need net
}

start_pre() {
    set -a
    # shellcheck disable=SC1091
    . /etc/podmaker/agent/agent.env
    set +a
}
EOF
        chmod 0755 /etc/init.d/podmaker-agent
        rc-update add podmaker-agent default >/dev/null 2>&1 || true
        ;;

    *)
        log "no recognised init system — agent will not auto-start"
        ;;
esac

# ---------------------------------------------------------------------------
# Phase 6: enrollment.
# ---------------------------------------------------------------------------

log "running enrollment"
if ! env $(cat "$ENV_FILE" | xargs) "$BIN_PATH" enroll; then
    fail "enrollment failed — see logs above" 4
fi

# Once enrollment is done the OTT must never be reused; redact the file.
shred -u "$ENROLL_FILE" 2>/dev/null || rm -f "$ENROLL_FILE"

# ---------------------------------------------------------------------------
# Phase 7: start the service.
# ---------------------------------------------------------------------------

case "$INIT_SYSTEM" in
    systemd)
        systemctl enable --now podmaker-agent.service \
            || fail "systemctl enable failed" 3
        sleep 2
        if ! systemctl is-active --quiet podmaker-agent.service; then
            systemctl status podmaker-agent.service --no-pager || true
            fail "podmaker-agent.service did not stay up" 3
        fi
        ;;
    openrc)
        rc-service podmaker-agent start || fail "rc-service start failed" 3
        ;;
esac

log "install complete"
