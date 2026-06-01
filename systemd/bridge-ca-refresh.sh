#!/bin/sh
# Pull the active CA + per-workspace CRL bundle from the control
# plane and rebuild the combined trust file the fronting proxy
# consumes. Designed to run as the `bridge-ca-refresh.service`
# oneshot unit; safe to run interactively as well.
#
# Required env (set via /etc/default/bridge-ca-refresh or systemd
# Environment= lines):
#
#   CP_URL              https://app.podmaker.sh
#   WORKSPACES          space- or comma-separated list of workspace
#                       ULIDs or slugs (CRLs are per-workspace, so
#                       one fetch per workspace)
#   TARGET_DIR          /etc/nginx/bridge-mtls (default)
#
# The script writes:
#
#   $TARGET_DIR/ca.pem        — active root CA
#   $TARGET_DIR/<ws>.crl.pem  — per-workspace CRL
#   $TARGET_DIR/crl.pem       — concatenated CRL bundle (all workspaces)
#
# Reloads nginx (or caddy) on success. Set RELOAD_CMD to override
# (e.g. `systemctl reload caddy`).

set -eu

CP_URL="${CP_URL:?CP_URL is required}"
WORKSPACES="${WORKSPACES:?WORKSPACES is required (space- or comma-separated)}"
TARGET_DIR="${TARGET_DIR:-/etc/nginx/bridge-mtls}"
RELOAD_CMD="${RELOAD_CMD:-systemctl reload nginx}"

log() { printf '[bridge-ca-refresh] %s\n' "$*"; }

mkdir -p "$TARGET_DIR"

# Atomic-write helper.
write_atomic() {
    target="$1"
    tmp="$target.tmp"
    cat > "$tmp"
    if ! [ -s "$tmp" ]; then
        rm -f "$tmp"
        log "ERROR: empty payload for $target"
        return 1
    fi
    chmod 0644 "$tmp"
    mv "$tmp" "$target"
}

log "fetching ca.pem from $CP_URL"
curl -fsSL "$CP_URL/api/v1/vault-bridges/ca.pem" | write_atomic "$TARGET_DIR/ca.pem"

bundle="$TARGET_DIR/crl.pem.tmp"
: > "$bundle"

for ws in $(echo "$WORKSPACES" | tr ',' ' '); do
    [ -z "$ws" ] && continue
    log "fetching CRL for workspace $ws"
    out="$TARGET_DIR/$ws.crl.pem"
    if curl -fsSL "$CP_URL/api/v1/vault-bridges/workspaces/$ws/crl.pem" | write_atomic "$out"; then
        cat "$out" >> "$bundle"
    else
        log "WARN: failed CRL fetch for $ws — keeping previous"
    fi
done

mv "$bundle" "$TARGET_DIR/crl.pem"
chmod 0644 "$TARGET_DIR/crl.pem"

log "reload via: $RELOAD_CMD"
$RELOAD_CMD || log "WARN: reload returned non-zero — check $RELOAD_CMD output"

log "done"
