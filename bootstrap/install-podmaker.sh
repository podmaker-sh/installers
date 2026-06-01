#!/bin/sh
# PodMaker one-shot installer.
#
# Idempotent host bootstrap that takes a bare VPS to a running CP:
#
#   1. Detect OS + arch, refuse if unsupported
#   2. Install Docker Engine + compose plugin if missing
#   3. Create /opt/podmaker tree (data + secrets + caddy)
#   4. Pull docker-compose.bootstrap.yml + Caddyfile from this CP
#   5. Generate dev secrets (or fetch ops bundle when SECRETS_URL set)
#   6. Bring up postgres + redis + openbao-meta + caddy + control-plane
#   7. Run `php artisan podmaker:bootstrap` inside the CP container
#      → migrations + ops workspace + admin user
#   8. Print panel URL + first-login magic link
#
# Re-running the script is safe: every step short-circuits when the
# resource already exists. Re-runs are how operators apply upgrades
# in the bootstrap phase (until self-update / sprint 3 lands).
#
# Usage:
#
#   curl -fsSL https://app.podmaker.sh/install/bootstrap | sh -s -- \
#       --domain panel.acme.io --email ops@acme.io
#
# Or with the env-var alternative:
#
#   PODMAKER_DOMAIN=panel.acme.io PODMAKER_EMAIL=ops@acme.io \
#     curl -fsSL https://app.podmaker.sh/install/bootstrap | sh
#

set -eu

# --- option parsing ----------------------------------------------------------

DOMAIN="${PODMAKER_DOMAIN:-}"
EMAIL="${PODMAKER_EMAIL:-}"
PREFIX="${PODMAKER_PREFIX:-/opt/podmaker}"
RELEASE="${PODMAKER_RELEASE:-latest}"
SOURCE_BASE="${PODMAKER_SOURCE_BASE:-https://app.podmaker.sh/install/bootstrap-files}"
NONINTERACTIVE="${PODMAKER_NONINTERACTIVE:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)  DOMAIN="$2"; shift 2 ;;
        --email)   EMAIL="$2";  shift 2 ;;
        --prefix)  PREFIX="$2"; shift 2 ;;
        --release) RELEASE="$2"; shift 2 ;;
        --source)  SOURCE_BASE="$2"; shift 2 ;;
        --noninteractive|-y) NONINTERACTIVE=1; shift ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^#\s\?//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

log() { printf '\033[1;36m[podmaker]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[podmaker] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- pre-flight --------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        log "re-executing under sudo"
        exec sudo -E DOMAIN="$DOMAIN" EMAIL="$EMAIL" PREFIX="$PREFIX" \
                    RELEASE="$RELEASE" SOURCE_BASE="$SOURCE_BASE" \
                    NONINTERACTIVE="$NONINTERACTIVE" sh "$0" "$@"
    fi
    die "must run as root (no sudo available)"
fi

case "$(uname -s)" in
    Linux) ;;
    *)     die "only Linux is supported in the bootstrap phase (Darwin/Windows planned)" ;;
esac

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported arch: $(uname -m)" ;;
esac

if [ -z "$DOMAIN" ] && [ "$NONINTERACTIVE" = "0" ] && [ -t 0 ]; then
    printf 'Panel domain (e.g. panel.acme.io): '; read -r DOMAIN
fi
if [ -z "$EMAIL" ] && [ "$NONINTERACTIVE" = "0" ] && [ -t 0 ]; then
    printf 'Operator email (for ACME + admin user): '; read -r EMAIL
fi
[ -n "$DOMAIN" ] || die "--domain is required"
[ -n "$EMAIL"  ] || die "--email is required"

# --- docker engine ------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    log "installing Docker Engine"
    curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
    die "docker compose plugin missing — install docker-compose-plugin and re-run"
fi
systemctl enable --now docker

# --- filesystem layout --------------------------------------------------------

log "preparing $PREFIX"
install -d -m 0755 "$PREFIX"
install -d -m 0700 "$PREFIX/secrets"
install -d -m 0755 "$PREFIX/caddy"   "$PREFIX/caddy/bridge-mtls"
install -d -m 0700 "$PREFIX/data"    "$PREFIX/data/postgres" "$PREFIX/data/redis" \
                   "$PREFIX/data/openbao-meta" "$PREFIX/data/caddy"

# --- fetch compose + Caddyfile -----------------------------------------------

fetch() {
    src="$1"; dst="$2"
    if [ ! -f "$dst" ]; then
        log "fetching $(basename "$dst")"
        curl -fsSL "${SOURCE_BASE}/${src}" -o "$dst"
    else
        log "$(basename "$dst") already present — keeping operator edits"
    fi
}

fetch docker-compose.bootstrap.yml "$PREFIX/docker-compose.yml"
fetch Caddyfile                    "$PREFIX/caddy/Caddyfile"
fetch caddy.env.template           "$PREFIX/secrets/caddy.env.template"
fetch control-plane.env.template   "$PREFIX/secrets/control-plane.env.template"

# --- generate secrets ---------------------------------------------------------

genpw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-48}"; }

write_secret() {
    target="$1"; shift
    template="$1"; shift
    if [ -f "$target" ]; then
        log "$(basename "$target") already exists — leaving secrets in place"
        return
    fi
    cp "$template" "$target"
    chmod 0600 "$target"
    for assignment in "$@"; do
        key=$(printf '%s' "$assignment" | cut -d= -f1)
        val=$(printf '%s' "$assignment" | cut -d= -f2-)
        sed -i "s|{{${key}}}|${val}|g" "$target"
    done
}

APP_KEY=$(genpw 32)
DB_PASS=$(genpw 32)
META_TOKEN=$(genpw 32)
INTERNAL=$(genpw 64)

write_secret "$PREFIX/secrets/caddy.env" \
             "$PREFIX/secrets/caddy.env.template" \
             "DOMAIN=$DOMAIN" \
             "EMAIL=$EMAIL"

write_secret "$PREFIX/secrets/control-plane.env" \
             "$PREFIX/secrets/control-plane.env.template" \
             "APP_KEY=base64:$(printf '%s' "$APP_KEY" | base64)" \
             "APP_URL=https://$DOMAIN" \
             "DB_PASSWORD=$DB_PASS" \
             "OPENBAO_META_TOKEN=$META_TOKEN" \
             "INTERNAL_TOKEN=$INTERNAL"

# --- bring stack up -----------------------------------------------------------

log "starting containers"
cd "$PREFIX"
PODMAKER_RELEASE="$RELEASE" docker compose pull
PODMAKER_RELEASE="$RELEASE" docker compose up -d

log "waiting for control-plane to come online"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if docker compose exec -T control-plane php artisan inspire >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

log "running first-time bootstrap"
docker compose exec -T control-plane \
    php artisan podmaker:bootstrap \
        --domain="$DOMAIN" \
        --email="$EMAIL" \
        --noninteractive

# --- finish -------------------------------------------------------------------

cat <<TXT

\033[1;32m✓ PodMaker installed.\033[0m

  Panel:  https://${DOMAIN}
  Login:  open the URL — a magic link was just emailed to ${EMAIL}
  Logs:   cd ${PREFIX} && docker compose logs -f --tail=100
  Stop:   cd ${PREFIX} && docker compose down

DNS reminder:
  point an A/AAAA record for ${DOMAIN} at this server's public IP.
  Caddy obtains the LE cert on first request — that takes ~30s.

Upgrade later:
  PODMAKER_RELEASE=v0.2.0 curl -fsSL ${SOURCE_BASE%/install/*}/install/bootstrap | sh
TXT
