#!/bin/sh
# PodMaker one-shot installer.
#
# Idempotent host bootstrap that takes a bare VPS to a running CP:
#
#   1. Detect OS + arch, refuse if unsupported
#   2. Install Docker Engine + compose plugin if missing
#   3. Create /opt/podmaker tree (compose + caddy + secrets + infra)
#   4. Materialise the tier YAML (default: t1-single-host-aws) into
#      /var/podmaker/tier-current.yaml so pdctl + orchestrator can
#      diff against future tiers
#   5. Generate every service secret (control-plane + 9 Go services
#      + postgres + temporal + step-ca) into PREFIX/secrets/*.env
#   6. docker compose up -d:
#        - prod mode (default): every service in docker-compose.prod.yml
#          → 20-service all-container SaaS stack
#        - bootstrap mode (--mode bootstrap): caddy + control-plane
#          + postgres + redis + openbao-meta only
#   7. Run `php artisan podmaker:bootstrap` inside the CP container
#      → migrations + ops workspace + admin user
#   8. Extract the step-ca root fingerprint (prod mode) and stamp it
#      into control-plane.env so freshly-minted agent install scripts
#      get real cert pinning
#   9. Print panel URL + first-login magic link
#
# Re-running the script is safe: every step short-circuits when the
# resource already exists. Re-runs refresh agent SHA-256 checksums +
# the step-ca fingerprint without overwriting operator edits.
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
# Tier YAML drives which compose file + secret set to materialise.
# Defaults to the all-container single-host shape (T1 AWS-flavoured;
# the same compose works on any IaaS — the AWS suffix is only a hint
# to operators reading the file list).
TIER="${PODMAKER_TIER:-t1-single-host-aws}"
# When SOURCE_BASE is file://, the script reads files from a rsync'd
# local checkout instead of curling them. Used by aws-ec2-bootstrap.sh
# and the manual fallback flow.
MODE="${PODMAKER_MODE:-prod}"

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)  DOMAIN="$2"; shift 2 ;;
        --email)   EMAIL="$2";  shift 2 ;;
        --prefix)  PREFIX="$2"; shift 2 ;;
        --release) RELEASE="$2"; shift 2 ;;
        --source)  SOURCE_BASE="$2"; shift 2 ;;
        --tier)    TIER="$2"; shift 2 ;;
        --mode)    MODE="$2"; shift 2 ;;
        --noninteractive|-y) NONINTERACTIVE=1; shift ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^#\s\?//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

case "$MODE" in
    prod|bootstrap) ;;
    *) echo "--mode must be prod (full SaaS stack) or bootstrap (5-service stack)" >&2; exit 1 ;;
esac

log() { printf '\033[1;36m[podmaker]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[podmaker] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- pre-flight --------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        log "re-executing under sudo"
        exec sudo -E PODMAKER_DOMAIN="$DOMAIN" PODMAKER_EMAIL="$EMAIL" \
                     PODMAKER_PREFIX="$PREFIX" PODMAKER_RELEASE="$RELEASE" \
                     PODMAKER_SOURCE_BASE="$SOURCE_BASE" \
                     PODMAKER_NONINTERACTIVE="$NONINTERACTIVE" \
                     PODMAKER_TIER="$TIER" PODMAKER_MODE="$MODE" \
                     PODMAKER_GHCR_USERNAME="${PODMAKER_GHCR_USERNAME:-}" \
                     PODMAKER_GHCR_TOKEN="${PODMAKER_GHCR_TOKEN:-}" \
                     PODMAKER_IMAGE_REGISTRY="${PODMAKER_IMAGE_REGISTRY:-}" \
                     sh "$0" "$@"
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
    log "installing Docker Engine + compose plugin"
    curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
    # Compose plugin missing but docker is installed (e.g. host used
    # Ubuntu's docker.io package). Fetch the standalone plugin binary
    # so we don't need to swap the docker engine.
    log "installing docker compose plugin (standalone binary)"
    case "$ARCH" in
        amd64) CMP_ARCH=x86_64 ;;
        arm64) CMP_ARCH=aarch64 ;;
        *) die "unsupported arch for compose plugin: $ARCH" ;;
    esac
    install -d -m 0755 /usr/local/lib/docker/cli-plugins
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${CMP_ARCH}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose
    docker compose version >/dev/null 2>&1 \
        || die "docker compose plugin install failed"
fi
systemctl enable --now docker

# --- filesystem layout --------------------------------------------------------

log "preparing $PREFIX (mode=$MODE, tier=$TIER)"
install -d -m 0755 "$PREFIX"
install -d -m 0700 "$PREFIX/secrets"
install -d -m 0755 "$PREFIX/caddy"   "$PREFIX/caddy/bridge-mtls"
install -d -m 0755 "$PREFIX/infra"   "$PREFIX/infra/vault/openbao" \
                                     "$PREFIX/infra/dev/nats" \
                                     "$PREFIX/infra/dev/zot" \
                                     "$PREFIX/infra/dev/temporal" \
                                     "$PREFIX/tiers"
install -d -m 0700 /var/podmaker

# --- fetch compose + Caddyfile + templates + infra ---------------------------
#
# fetch supports two source kinds:
#   1. file://<dir>  — copy from a local rsync'd checkout (set by
#      aws-ec2-bootstrap.sh or the manual fallback).
#   2. https://...   — curl (the legacy hosted-panel path).
# When the destination already exists we preserve operator edits.

#
# When force=1 (default for compose + Caddyfile + templates + infra
# payloads), an existing destination is overwritten so re-runs pick
# up the latest checked-in artefacts. Secrets (rendered .env files)
# never go through fetch — they have their own preservation logic.
fetch() {
    src="$1"; dst="$2"; force="${3:-1}"
    if [ "$force" != "1" ] && [ -f "$dst" ]; then
        log "$(basename "$dst") already present — keeping operator edits"
        return
    fi
    case "$SOURCE_BASE" in
        file://*)
            srcfile="${SOURCE_BASE#file://}/${src}"
            log "copying $srcfile"
            install -m 0644 "$srcfile" "$dst"
            ;;
        *)
            log "fetching $(basename "$dst")"
            curl -fsSL "${SOURCE_BASE}/${src}" -o "$dst"
            ;;
    esac
}

if [ "$MODE" = "prod" ]; then
    COMPOSE_SRC="deploy/docker-compose.prod.yml"
else
    COMPOSE_SRC="deploy/docker-compose.bootstrap.yml"
fi

fetch "$COMPOSE_SRC"                                 "$PREFIX/docker-compose.yml"
fetch "deploy/caddy/Caddyfile"                       "$PREFIX/caddy/Caddyfile"
fetch "deploy/bootstrap-templates/caddy.env.template"        "$PREFIX/secrets/caddy.env.template"
fetch "deploy/bootstrap-templates/control-plane.env.template" "$PREFIX/secrets/control-plane.env.template"

if [ "$MODE" = "prod" ]; then
    # Prod-only secret templates (one per service in
    # docker-compose.prod.yml that carries env_file:).
    for tpl in orchestrator agent-gateway cloud-broker vault-broker \
               topology-planner build-service repo-scanner \
               postgres temporal step-ca; do
        fetch "deploy/bootstrap-templates/${tpl}.env.template" \
              "$PREFIX/secrets/${tpl}.env.template"
    done

    # Bind-mount config payloads referenced by docker-compose.prod.yml
    # via the relative `../infra/...` paths.
    fetch "infra/vault/openbao/config.hcl"   "$PREFIX/infra/vault/openbao/config.hcl"
    fetch "infra/vault/openbao/entrypoint.sh" "$PREFIX/infra/vault/openbao/entrypoint.sh"
    chmod 0755 "$PREFIX/infra/vault/openbao/entrypoint.sh" 2>/dev/null || true
    fetch "infra/dev/nats/hub.conf"          "$PREFIX/infra/dev/nats/hub.conf"
    fetch "infra/dev/nats/leaf.conf"         "$PREFIX/infra/dev/nats/leaf.conf"
    fetch "infra/dev/nats/leaf-eu-west.conf" "$PREFIX/infra/dev/nats/leaf-eu-west.conf"
    fetch "infra/dev/nats/leaf-apac.conf"    "$PREFIX/infra/dev/nats/leaf-apac.conf"
    fetch "infra/dev/zot/config.json"        "$PREFIX/infra/dev/zot/config.json"
    fetch "infra/dev/temporal/development-sql.yaml" "$PREFIX/infra/dev/temporal/development-sql.yaml"

    # The prod compose references infra/ via `../infra/...` because it
    # lives under deploy/. Our $PREFIX layout flattens that — rewrite
    # the paths in-place so docker compose resolves them correctly.
    sed -i 's|\.\./infra/|./infra/|g' "$PREFIX/docker-compose.yml"

    # Stamp the tier file so pdctl + the orchestrator know which YAML
    # the live deployment was minted from.
    fetch "tiers/${TIER}.yaml" "$PREFIX/tiers/${TIER}.yaml" || \
        die "tier not found: ${TIER}.yaml under ${SOURCE_BASE}"
    install -m 0644 "$PREFIX/tiers/${TIER}.yaml" /var/podmaker/tier-current.yaml
fi

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

# upsert_env_var <file> <KEY> <VALUE>
# Idempotent: replaces existing `KEY=...` or appends. Skipped when
# VALUE is empty so we never blank out a previously-stamped value.
upsert_env_var() {
    file="$1"; key="$2"; val="$3"
    [ -n "$val" ] || return 0
    [ -f "$file" ] || return 0
    if grep -qE "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
    fi
}

# fetch_agent_sha256 <arch>  →  prints sha hex or empty
# Pulls checksums.txt from PODMAKER_AGENT_RELEASE_BASE and parses
# the `podmaker-agent-linux-<arch>.tar.gz` line. Silent on failure
# so the install script keeps working in air-gapped envs.
fetch_agent_sha256() {
    arch="$1"
    base="${PODMAKER_AGENT_RELEASE_BASE:-https://github.com/podmaker-sh/releases/releases/latest/download}"
    curl -fsSL --max-time 30 "${base}/checksums.txt" 2>/dev/null \
        | awk -v a="podmaker-agent-linux-${arch}.tar.gz" '$2==a || $2=="*"a {print $1; exit}'
}

# extract_step_ca_fingerprint  →  prints fingerprint hex or empty
# Only works once the full prod stack is up (step-ca service
# present). Bootstrap stack omits step-ca, so this silently
# returns empty — operator re-runs install-podmaker.sh after the
# layered services land and the value gets upserted then.
extract_step_ca_fingerprint() {
    docker compose ps --services 2>/dev/null | grep -qx step-ca || return 0
    docker compose exec -T step-ca \
        step certificate fingerprint /home/step/certs/root_ca.crt 2>/dev/null \
        | tr -d '[:space:]'
}

APP_KEY=$(genpw 32)
DB_PASS=$(genpw 32)
META_TOKEN=$(genpw 32)
INTERNAL=$(genpw 64)
STEPCA_PASSWORD=$(genpw 48)

# Derive the bare apex from panel.<apex> so step-ca's DNS SANs and
# the agent gateway URL match what the panel hands out at install time.
APEX=$(printf '%s' "$DOMAIN" | sed 's/^panel\.//')

log "fetching agent release checksums"
SHA_AMD64=$(fetch_agent_sha256 amd64 || true)
SHA_ARM64=$(fetch_agent_sha256 arm64 || true)
[ -n "$SHA_AMD64" ] || log "  amd64 checksum unavailable — agent installs will fall back to PODMAKER_AGENT_ALLOW_UNVERIFIED=1"
[ -n "$SHA_ARM64" ] || log "  arm64 checksum unavailable — agent installs will fall back to PODMAKER_AGENT_ALLOW_UNVERIFIED=1"

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
             "INTERNAL_TOKEN=$INTERNAL" \
             "AGENT_SHA256_AMD64=$SHA_AMD64" \
             "AGENT_SHA256_ARM64=$SHA_ARM64" \
             "STEP_CA_FINGERPRINT="

# Re-runs: refresh checksums in case a new agent release shipped.
upsert_env_var "$PREFIX/secrets/control-plane.env" PODMAKER_AGENT_SHA256_AMD64 "$SHA_AMD64"
upsert_env_var "$PREFIX/secrets/control-plane.env" PODMAKER_AGENT_SHA256_ARM64 "$SHA_ARM64"

if [ "$MODE" = "prod" ]; then
    # Per-service env files. Every Go service shares INTERNAL_TOKEN +
    # in-cluster service hostnames.
    write_secret "$PREFIX/secrets/orchestrator.env" \
                 "$PREFIX/secrets/orchestrator.env.template" \
                 "INTERNAL_TOKEN=$INTERNAL"
    write_secret "$PREFIX/secrets/agent-gateway.env" \
                 "$PREFIX/secrets/agent-gateway.env.template" \
                 "INTERNAL_TOKEN=$INTERNAL"
    write_secret "$PREFIX/secrets/cloud-broker.env" \
                 "$PREFIX/secrets/cloud-broker.env.template" \
                 "INTERNAL_TOKEN=$INTERNAL"
    write_secret "$PREFIX/secrets/vault-broker.env" \
                 "$PREFIX/secrets/vault-broker.env.template" \
                 "INTERNAL_TOKEN=$INTERNAL"
    write_secret "$PREFIX/secrets/topology-planner.env" \
                 "$PREFIX/secrets/topology-planner.env.template" \
                 "INTERNAL_TOKEN=$INTERNAL"
    write_secret "$PREFIX/secrets/build-service.env" \
                 "$PREFIX/secrets/build-service.env.template" \
                 "INTERNAL_TOKEN=$INTERNAL"
    write_secret "$PREFIX/secrets/repo-scanner.env" \
                 "$PREFIX/secrets/repo-scanner.env.template" \
                 "INTERNAL_TOKEN=$INTERNAL"
    write_secret "$PREFIX/secrets/postgres.env" \
                 "$PREFIX/secrets/postgres.env.template" \
                 "DB_PASSWORD=$DB_PASS"
    write_secret "$PREFIX/secrets/temporal.env" \
                 "$PREFIX/secrets/temporal.env.template" \
                 "DB_PASSWORD=$DB_PASS"
    write_secret "$PREFIX/secrets/step-ca.env" \
                 "$PREFIX/secrets/step-ca.env.template" \
                 "STEPCA_PASSWORD=$STEPCA_PASSWORD" \
                 "APEX=$APEX"

    # Compose interpolates these from a `.env` file in the project
    # directory. PODMAKER_IMAGE_REGISTRY lets operators host their
    # own GHCR namespace / private registry mirror without editing
    # the compose file.
    IMG_REGISTRY="${PODMAKER_IMAGE_REGISTRY:-ghcr.io/podmaker-sh}"
    if [ ! -f "$PREFIX/.env" ]; then
        cat > "$PREFIX/.env" <<EOF
OPENBAO_META_TOKEN_ID=$META_TOKEN
PODMAKER_RELEASE=$RELEASE
PODMAKER_IMAGE_REGISTRY=$IMG_REGISTRY
PODMAKER_HOST_ARCH=$ARCH
EOF
        chmod 0600 "$PREFIX/.env"
    else
        upsert_env_var "$PREFIX/.env" PODMAKER_IMAGE_REGISTRY "$IMG_REGISTRY"
    fi

    # Hand the step-ca provisioner password to the panel so the
    # JWT-OTT minter can talk to step-ca without docker exec.
    upsert_env_var "$PREFIX/secrets/control-plane.env" \
        PODMAKER_STEPCA_PROVISIONER_PASSWORD "$STEPCA_PASSWORD"
fi

# --- bring stack up -----------------------------------------------------------

# GHCR private images need auth. Operator exports
# PODMAKER_GHCR_USERNAME + PODMAKER_GHCR_TOKEN (PAT with read:packages).
# Skipped when either is unset — docker pull will surface the auth
# failure clearly.
if [ -n "${PODMAKER_GHCR_TOKEN:-}" ] && [ -n "${PODMAKER_GHCR_USERNAME:-}" ]; then
    log "logging into ghcr.io as $PODMAKER_GHCR_USERNAME"
    printf '%s' "$PODMAKER_GHCR_TOKEN" | \
        docker login ghcr.io -u "$PODMAKER_GHCR_USERNAME" --password-stdin
fi

# DOCR (DigitalOcean Container Registry) auth — terraform writes the
# auth config to /root/.docker/config.json via cloud-init when
# var.enable_managed_registry is on. We also accept PODMAKER_DOCR_AUTH_B64
# at install time so an operator running install-podmaker.sh directly
# (not via cloud-init) gets the same path.
if [ -n "${PODMAKER_DOCR_AUTH_B64:-}" ]; then
    log "writing DOCR auth config from PODMAKER_DOCR_AUTH_B64"
    install -d -m 0700 /root/.docker
    printf '%s' "$PODMAKER_DOCR_AUTH_B64" | base64 -d > /root/.docker/config.json
    chmod 0600 /root/.docker/config.json
fi

log "starting containers"
cd "$PREFIX"
PODMAKER_RELEASE="$RELEASE" docker compose pull
PODMAKER_RELEASE="$RELEASE" docker compose up -d

log "waiting for postgres to fully start (accepts queries, not just connections)"
for i in $(seq 1 60); do
    if docker compose exec -T postgres psql -U podmaker -d podmaker -c 'SELECT 1' >/dev/null 2>&1; then
        log "  postgres ready"
        break
    fi
    sleep 2
    [ "$i" = "60" ] && die "postgres never finished starting up"
done

log "waiting for control-plane to come online"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if docker compose exec -T control-plane php artisan inspire >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

log "running first-time bootstrap (migrations + ops workspace; superadmin claimed via /setup wizard)"
docker compose exec -T control-plane \
    php artisan podmaker:bootstrap \
        --domain="$DOMAIN" \
        --email="$EMAIL" \
        --no-admin \
        --noninteractive

# Stamp the step-ca root fingerprint once the layered prod stack
# is in play. Bootstrap-only stack omits step-ca → silent no-op.
STEP_CA_FP=$(extract_step_ca_fingerprint || true)
if [ -n "$STEP_CA_FP" ]; then
    log "stamping step-ca root fingerprint into control-plane.env"
    upsert_env_var "$PREFIX/secrets/control-plane.env" PODMAKER_STEP_CA_FINGERPRINT "$STEP_CA_FP"
    docker compose restart control-plane >/dev/null 2>&1 || true
else
    log "step-ca not running in this stack — fingerprint not stamped (re-run after the prod stack is up to fill it)"
fi

# --- finish -------------------------------------------------------------------

cat <<TXT

\033[1;32m✓ PodMaker installed.\033[0m

  Panel:  https://${DOMAIN}
  Setup:  open https://${DOMAIN}/setup and claim the superadmin slot
  Logs:   cd ${PREFIX} && docker compose logs -f --tail=100
  Stop:   cd ${PREFIX} && docker compose down

DNS reminder:
  point an A/AAAA record for ${DOMAIN} at this server's public IP.
  Caddy obtains the LE cert on first request — that takes ~30s.

Upgrade later:
  PODMAKER_RELEASE=v0.2.0 curl -fsSL ${SOURCE_BASE%/install/*}/install/bootstrap | sh
TXT
