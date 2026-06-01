#!/bin/sh
# One-liner installer for the podmaker-vault-bridge agent.
#
# Usage:
#   curl -fsSL https://app.podmaker.sh/install/vault-bridge | sh
#
# Or with overrides:
#   PODMAKER_BRIDGE_VERSION=v0.3.1 \
#   PODMAKER_BRIDGE_PREFIX=/opt/podmaker \
#   curl -fsSL https://app.podmaker.sh/install/vault-bridge | sh -s --
#
# The script detects OS + architecture, downloads the matching
# release tarball from GitHub, verifies the SHA-256, drops the
# binary at $PREFIX/bin/podmaker-vault-bridge, and prints the
# next-step env-var template.
#
# No Go toolchain required.

set -eu

REPO="${PODMAKER_BRIDGE_REPO:-}"
VERSION="${PODMAKER_BRIDGE_VERSION:-latest}"
PREFIX="${PODMAKER_BRIDGE_PREFIX:-/usr/local}"
PROVIDER="${PODMAKER_BRIDGE_PROVIDER:-github}"
HOST="${PODMAKER_BRIDGE_HOST:-}"
BASE_URL_OVERRIDE="${PODMAKER_BRIDGE_BASE_URL:-}"

# Either a full base URL or a repo + provider must be supplied.
# The CP installer endpoint stamps these before piping the script
# — fresh downloads with neither set are a misconfiguration.
if [ -z "$REPO" ] && [ -z "$BASE_URL_OVERRIDE" ]; then
    printf '[podmaker-vault-bridge] ERROR: PODMAKER_BRIDGE_REPO or PODMAKER_BRIDGE_BASE_URL must be set\n' >&2
    exit 1
fi

# Default per-provider host when the operator did not set PODMAKER_BRIDGE_HOST.
if [ -z "$HOST" ]; then
    case "$PROVIDER" in
        github)          HOST="github.com" ;;
        gitea|forgejo)   HOST="gitea.com" ;;
        gitlab)          HOST="gitlab.com" ;;
        bitbucket)       HOST="bitbucket.org" ;;
    esac
fi
BIN_DIR="$PREFIX/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { printf '[podmaker-vault-bridge] %s\n' "$*"; }
die() { printf '[podmaker-vault-bridge] ERROR: %s\n' "$*" >&2; exit 1; }

# --- detect host platform ------------------------------------------
case "$(uname -s)" in
    Linux)   OS=linux ;;
    Darwin)  OS=darwin ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *)       die "unsupported OS: $(uname -s)" ;;
esac

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) die "unsupported arch: $(uname -m)" ;;
esac

# Windows builds skip the tarball; binary is `.exe`.
if [ "$OS" = "windows" ] && [ "$ARCH" = "arm64" ]; then
    die "windows/arm64 is not published yet; build from source with `make bridge-release`"
fi

# --- resolve download URL ------------------------------------------
PLATFORM="${OS}-${ARCH}"
ASSET="podmaker-vault-bridge-${PLATFORM}.tar.gz"

if [ -n "$BASE_URL_OVERRIDE" ]; then
    BASE_URL="$BASE_URL_OVERRIDE"
else
    case "$PROVIDER" in
        github)
            if [ "$VERSION" = "latest" ]; then
                BASE_URL="https://${HOST}/${REPO}/releases/latest/download"
            else
                BASE_URL="https://${HOST}/${REPO}/releases/download/${VERSION}"
            fi
            ;;
        gitea|forgejo)
            if [ "$VERSION" = "latest" ]; then
                BASE_URL="https://${HOST}/${REPO}/releases/download/latest"
            else
                BASE_URL="https://${HOST}/${REPO}/releases/download/${VERSION}"
            fi
            ;;
        gitlab)
            if [ "$VERSION" = "latest" ]; then
                BASE_URL="https://${HOST}/${REPO}/-/releases/permalink/latest/downloads"
            else
                BASE_URL="https://${HOST}/${REPO}/-/releases/${VERSION}/downloads"
            fi
            ;;
        bitbucket)
            BASE_URL="https://${HOST}/${REPO}/downloads"
            ;;
        *)
            die "unknown PODMAKER_BRIDGE_PROVIDER '$PROVIDER' — set PODMAKER_BRIDGE_BASE_URL to the full prefix instead"
            ;;
    esac
fi
TARBALL_URL="${BASE_URL}/${ASSET}"
SHA_URL="${TARBALL_URL}.sha256"

log "downloading ${ASSET} from ${BASE_URL}"
curl -fsSL "$TARBALL_URL" -o "$TMP/$ASSET"
curl -fsSL "$SHA_URL"     -o "$TMP/$ASSET.sha256"

# --- verify checksum ----------------------------------------------
EXPECTED="$(cat "$TMP/$ASSET.sha256" | awk '{print $1}')"
case "$(uname)" in
    Darwin) ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')" ;;
    *)      ACTUAL="$(sha256sum   "$TMP/$ASSET" | awk '{print $1}')" ;;
esac
if [ "$EXPECTED" != "$ACTUAL" ]; then
    die "checksum mismatch: expected $EXPECTED got $ACTUAL"
fi
log "checksum OK ($ACTUAL)"

# --- extract + install --------------------------------------------
tar -xzf "$TMP/$ASSET" -C "$TMP"
BIN_SRC="$TMP/podmaker-vault-bridge-${PLATFORM}"
[ "$OS" = "windows" ] && BIN_SRC="${BIN_SRC}.exe"

if [ ! -f "$BIN_SRC" ]; then
    die "tarball did not contain the expected binary $BIN_SRC"
fi

INSTALL_TARGET="$BIN_DIR/podmaker-vault-bridge"
[ "$OS" = "windows" ] && INSTALL_TARGET="${INSTALL_TARGET}.exe"

if [ ! -d "$BIN_DIR" ]; then
    mkdir -p "$BIN_DIR" 2>/dev/null || sudo mkdir -p "$BIN_DIR"
fi

if [ -w "$BIN_DIR" ]; then
    install -m 0755 "$BIN_SRC" "$INSTALL_TARGET"
else
    log "installing with sudo (target $BIN_DIR not writable)"
    sudo install -m 0755 "$BIN_SRC" "$INSTALL_TARGET"
fi

log "installed -> $INSTALL_TARGET"
"$INSTALL_TARGET" -version 2>/dev/null || true

cat <<EOF

Next steps:
  1. Register a bridge in the PodMaker admin (Infrastructure → Vault bridges)
     and copy the bearer token shown on the success page.
  2. Run the agent. For AWS Secrets Manager via aws-vault:

     aws-vault exec PROFILE -- \\
       PODMAKER_BRIDGE_ID=<bridge_id> \\
       PODMAKER_BRIDGE_TOKEN=<token> \\
       PODMAKER_CP_URL=https://app.podmaker.sh \\
       PODMAKER_UPSTREAM_TYPE=aws-sm \\
       podmaker-vault-bridge

  3. The first start provisions an mTLS cert under
     ~/.podmaker-bridge — keep that directory around for renewals.
EOF
