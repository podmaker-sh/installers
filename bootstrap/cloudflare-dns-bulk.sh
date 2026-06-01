#!/usr/bin/env bash
# cloudflare-dns-bulk.sh — upsert every PodMaker subdomain A record
# pointing at the given IP, in one shot, via the Cloudflare API.
#
# Idempotent — re-running with a different --ip rewrites the records
# in place (delete-on-conflict + create), so this is also the right
# tool for swapping DNS after a teardown + fresh deploy.
#
# Prereqs:
#   - CF API token with Zone.DNS:Edit + Zone.Zone:Read on the zone,
#     exported as CF_API_TOKEN (or CLOUDFLARE_API_TOKEN).
#   - curl + jq on PATH.
#
# Usage:
#   ./scripts/bootstrap/cloudflare-dns-bulk.sh --zone podmaker.sh --ip 1.2.3.4
#   ./scripts/bootstrap/cloudflare-dns-bulk.sh --zone acme.io     --ip 1.2.3.4 --dry-run
#   ./scripts/bootstrap/cloudflare-dns-bulk.sh --zone podmaker.sh --ip 1.2.3.4 --proxied
#
# Each record is created proxied=false (DNS-only) by default so Caddy
# can do its own LE / mTLS without Cloudflare's edge in the middle.
# The agents.<apex> endpoint requires direct origin TLS (mTLS), so
# leave proxy off unless you know what you're doing.

set -euo pipefail

ZONE=""
IP=""
PROXIED=false
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --zone)    ZONE="$2"; shift 2 ;;
        --ip)      IP="$2"; shift 2 ;;
        --proxied) PROXIED=true; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h)
            sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -n "$ZONE" ] || { echo "--zone required" >&2; exit 1; }
[ -n "$IP"   ] || { echo "--ip required"   >&2; exit 1; }
command -v curl >/dev/null || { echo "curl not on PATH" >&2; exit 1; }
command -v jq   >/dev/null || { echo "jq not on PATH"   >&2; exit 1; }
TOKEN="${CLOUDFLARE_API_TOKEN:-${CF_API_TOKEN:-}}"
[ -n "$TOKEN" ] || { echo "set CF_API_TOKEN (or CLOUDFLARE_API_TOKEN)" >&2; exit 1; }

# Subdomain set — keep in sync with deploy/caddy/Caddyfile and
# infra/topology/ops.yaml.
NAMES=(
    "@"               # apex — marketing site
    www               # marketing
    panel             # Filament admin + tenant panel
    api               # public Sanctum API
    app               # install bootstrap URL (curl … app.X/install/bootstrap)
    agents            # WSS to enrolled agents (proxy MUST be off)
    docs              # static docs mirror
    builds            # build-service (tenant builds)
    registry          # zot OCI registry
    temporal          # temporal-ui (operator-only, SSH-forwarded in T1)
    vault             # openbao tenant (operator-only, SSH-forwarded in T1)
    vault-meta        # openbao meta (operator-only, SSH-forwarded in T1)
    nats              # nats monitoring (operator-only, SSH-forwarded in T1)
    ca                # step-ca (operator-only, SSH-forwarded in T1)
    status            # redirect to status.io
    nats-us-east      # regional NATS leaf gateway
    nats-eu-west
    nats-apac
)

log()  { printf '\033[1;36m[cf-dns]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[cf-dns]\033[0m %s\n' "$*" >&2; }

cf() {
    local method="$1"; shift
    local path="$1"; shift
    # Don't pass -f — we need the body even on 4xx so the caller can
    # introspect the CF error code (e.g. duplicate record vs auth).
    if [ "$#" -gt 0 ]; then
        curl -sS -X "$method" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            --data "$1" \
            "https://api.cloudflare.com/client/v4${path}"
    else
        curl -sS -X "$method" \
            -H "Authorization: Bearer $TOKEN" \
            "https://api.cloudflare.com/client/v4${path}"
    fi
}

log "zone     : $ZONE"
log "target IP: $IP"
log "proxied  : $PROXIED"
log "records  : ${#NAMES[@]}"
[ "$DRY_RUN" = "1" ] && log "DRY RUN — no API writes"

ZONE_ID=$(cf GET "/zones?name=$ZONE" | jq -r '.result[0].id // empty')
[ -n "$ZONE_ID" ] || { echo "zone $ZONE not found on this CF account" >&2; exit 1; }
log "zone id  : $ZONE_ID"

for n in "${NAMES[@]}"; do
    if [ "$n" = "@" ]; then
        fqdn="$ZONE"
    else
        fqdn="$n.$ZONE"
    fi

    # First sweep: kill any non-A record that shadows this name
    # (CNAME parking pages, leftover AAAA, etc.). CF refuses to
    # create an A while a CNAME with the same name exists.
    ALL_NAMED=$(cf GET "/zones/$ZONE_ID/dns_records?name=$fqdn" \
        | jq -r '.result[] | select(.type != "A") | .id + " " + .type')
    if [ -n "$ALL_NAMED" ]; then
        while read -r rid rtype; do
            [ -z "$rid" ] && continue
            warn "  removing $rtype record for $fqdn (id=$rid) so A can take its place"
            if [ "$DRY_RUN" = "0" ]; then
                cf DELETE "/zones/$ZONE_ID/dns_records/$rid" >/dev/null
            fi
        done <<< "$ALL_NAMED"
    fi

    EXISTING=$(cf GET "/zones/$ZONE_ID/dns_records?type=A&name=$fqdn" \
        | jq -r '.result[] | .id + " " + .content + " " + (.proxied|tostring)')

    if [ -z "$EXISTING" ]; then
        log "→ create $fqdn → $IP"
        if [ "$DRY_RUN" = "0" ]; then
            RESP=$(cf POST "/zones/$ZONE_ID/dns_records" \
                "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":$PROXIED}")
            SUCCESS=$(printf '%s' "$RESP" | jq -r '.success // false')
            if [ "$SUCCESS" != "true" ]; then
                ERR_MSG=$(printf '%s' "$RESP" | jq -r '.errors[]?.message // empty' | head -1)
                warn "  create failed for $fqdn: $ERR_MSG"
            fi
        fi
    else
        FIRST_ID=$(printf '%s\n' "$EXISTING" | head -1 | awk '{print $1}')
        FIRST_IP=$(printf '%s\n' "$EXISTING" | head -1 | awk '{print $2}')
        DUPES=$(printf '%s\n' "$EXISTING" | tail -n +2 | awk '{print $1}')

        if [ "$FIRST_IP" = "$IP" ]; then
            log "✓ $fqdn already → $IP"
        else
            log "↻ update $fqdn $FIRST_IP → $IP"
            if [ "$DRY_RUN" = "0" ]; then
                RESP=$(cf PUT "/zones/$ZONE_ID/dns_records/$FIRST_ID" \
                    "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":$PROXIED}")
                SUCCESS=$(printf '%s' "$RESP" | jq -r '.success // false')
                [ "$SUCCESS" != "true" ] && \
                    warn "  update failed for $fqdn: $(printf '%s' "$RESP" | jq -r '.errors[]?.message // empty' | head -1)"
            fi
        fi

        for d in $DUPES; do
            warn "  removing duplicate A record id=$d"
            if [ "$DRY_RUN" = "0" ]; then
                cf DELETE "/zones/$ZONE_ID/dns_records/$d" >/dev/null
            fi
        done
    fi
done

log "done."
echo "  verify: dig +short @1.1.1.1 panel.$ZONE api.$ZONE agents.$ZONE"
