#!/usr/bin/env bash
# t1-aws-fresh.sh — Tier-1 deploy on AWS, end to end.
#
# Resumable: keeps a state file under .dev/t1-aws-state.json that
# records the EC2 + EIP + SG + key pair + install/DNS phases. Re-running
# without --teardown picks up from where the last attempt stopped — no
# wasted instance creation, no re-billed EIP.
#
# What it does (in phases — each is idempotent):
#   1. Pre-flight: aws-cli / flarectl / rsync / ssh / jq on PATH,
#      AWS creds + CF_API_TOKEN + GHCR_PAT exported.
#   2. (Optional) Tear down the previous run's EC2 + EIP + Route53 A
#      records by tag (`--teardown` flag, or PODMAKER_TEARDOWN=1).
#   3. Provision: SG (idempotent), key pair (idempotent), EC2 (skip if
#      state has a running instance), Elastic IP (skip if associated).
#   4. Wait for SSH + cloud-init.
#   5. rsync bootstrap bundle to /opt/podmaker-src.
#   6. Run install-podmaker.sh (idempotent; respects existing secrets).
#   7. Cloudflare DNS upsert: all 18 A records to the current public IP.
#   8. Print panel URL + setup wizard URL.
#
# Required env vars (export before running):
#   AWS_REGION              e.g. eu-central-1
#   AWS_PROFILE             or AWS_ACCESS_KEY_ID/SECRET (aws-cli config)
#   CF_API_TOKEN            Cloudflare DNS:Edit on the apex zone
#   GHCR_PAT                ghp_… with read:packages + write:packages
#
# Required flags:
#   --domain panel.acme.io
#   --email  ops@acme.io
#
# Optional flags:
#   --apex acme.io                  (default: derived by stripping `panel.`)
#   --zone acme.io                  (default: same as apex)
#   --region eu-central-1           (or AWS_REGION env)
#   --instance-type t4g.xlarge
#   --disk-gib 80
#   --ssh-key-name podmaker-ops
#   --image-registry ghcr.io/<user> (default: podmaker-sh)
#   --ghcr-username <github-user>   (default: derive from --image-registry)
#   --tier t1-single-host-aws
#   --teardown                      (destroy everything, clear state, re-run)
#   --reset-state                   (discard state file; next phase decides)
#   --reinstall                     (re-run install step even if state says done)
#   --skip-dns                      (don't touch Cloudflare)
#   --skip-install                  (provision + rsync only — skip install + DNS)
#   --state-file <path>             (default: .dev/t1-aws-state.json)
#   --dry-run                       (print intended actions, no execution)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# --- args + defaults --------------------------------------------------------

DOMAIN=""
EMAIL=""
APEX=""
ZONE=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}"
INSTANCE_TYPE="t4g.xlarge"
DISK_GIB=80
SSH_KEY_NAME="podmaker-ops"
TIER="t1-single-host-aws"
IMAGE_REGISTRY="ghcr.io/podmaker-sh"
GHCR_USERNAME=""
TEARDOWN=0
RESET_STATE=0
REINSTALL=0
SKIP_DNS=0
SKIP_INSTALL=0
DRY_RUN=0
TAG_PROJECT="podmaker"
STATE_FILE="${PODMAKER_STATE_FILE:-$ROOT/.dev/t1-aws-state.json}"

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)         DOMAIN="$2"; shift 2 ;;
        --email)          EMAIL="$2"; shift 2 ;;
        --apex)           APEX="$2"; shift 2 ;;
        --zone)           ZONE="$2"; shift 2 ;;
        --region)         REGION="$2"; shift 2 ;;
        --instance-type)  INSTANCE_TYPE="$2"; shift 2 ;;
        --disk-gib)       DISK_GIB="$2"; shift 2 ;;
        --ssh-key-name)   SSH_KEY_NAME="$2"; shift 2 ;;
        --tier)           TIER="$2"; shift 2 ;;
        --image-registry) IMAGE_REGISTRY="$2"; shift 2 ;;
        --ghcr-username)  GHCR_USERNAME="$2"; shift 2 ;;
        --teardown)       TEARDOWN=1; shift ;;
        --reset-state)    RESET_STATE=1; shift ;;
        --reinstall)      REINSTALL=1; shift ;;
        --skip-dns)       SKIP_DNS=1; shift ;;
        --skip-install)   SKIP_INSTALL=1; shift ;;
        --state-file)     STATE_FILE="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --help|-h)        sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

log()  { printf '\033[1;36m[t1]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[t1]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[t1] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = "1" ]; then echo "  + $*"; else "$@"; fi; }

[ -n "$DOMAIN" ] || die "--domain required"
[ -n "$EMAIL"  ] || die "--email  required"
[ -n "$APEX" ]   || APEX=$(printf '%s' "$DOMAIN" | sed 's/^panel\.//')
[ -n "$ZONE" ]   || ZONE="$APEX"
[ -n "$GHCR_USERNAME" ] || GHCR_USERNAME=$(printf '%s' "$IMAGE_REGISTRY" | awk -F/ '{print $NF}')

# --- pre-flight -------------------------------------------------------------

for cmd in aws rsync ssh ssh-keygen jq curl; do
    command -v "$cmd" >/dev/null || die "$cmd not on PATH"
done
[ -n "${CF_API_TOKEN:-}${CLOUDFLARE_API_TOKEN:-}" ] || die "CF_API_TOKEN not exported"
[ -n "${GHCR_PAT:-}" ] || die "GHCR_PAT not exported"
export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$CF_API_TOKEN}"
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS creds not usable (configure aws-cli)"

PRIVATE_KEY="${HOME}/.ssh/${SSH_KEY_NAME}.pem"

mkdir -p "$(dirname "$STATE_FILE")"

# --- state helpers ----------------------------------------------------------

state_init() {
    [ -f "$STATE_FILE" ] && return
    cat > "$STATE_FILE" <<EOF
{"version":1,"region":"$REGION","domain":"$DOMAIN"}
EOF
}
state_get() {
    [ -f "$STATE_FILE" ] || { printf ''; return; }
    jq -r --arg k "$1" '.[$k] // ""' "$STATE_FILE"
}
state_set() {
    state_init
    tmp=$(mktemp)
    jq --arg k "$1" --arg v "$2" '.[$k]=$v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}
state_show() {
    [ -f "$STATE_FILE" ] && jq . "$STATE_FILE" 2>/dev/null || echo "{}"
}

if [ "$RESET_STATE" = "1" ]; then
    log "discarding state file $STATE_FILE"
    rm -f "$STATE_FILE"
fi

log "domain         : $DOMAIN"
log "apex / zone    : $APEX / $ZONE"
log "region         : $REGION"
log "instance       : $INSTANCE_TYPE / ${DISK_GIB} GB"
log "tier           : $TIER"
log "image registry : $IMAGE_REGISTRY (ghcr user $GHCR_USERNAME)"
log "state file     : $STATE_FILE"
log "phase flags    : teardown=$TEARDOWN reinstall=$REINSTALL skip-dns=$SKIP_DNS skip-install=$SKIP_INSTALL dry-run=$DRY_RUN"

# --- step 1: optional teardown ----------------------------------------------

if [ "$TEARDOWN" = "1" ]; then
    log "tearing down previous deploy (tagged Project=$TAG_PROJECT, Role=bootstrap)"
    OLD_INSTANCES=$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:Project,Values=$TAG_PROJECT" \
                  "Name=tag:Role,Values=bootstrap" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text)
    if [ -n "$OLD_INSTANCES" ]; then
        log "  terminating: $OLD_INSTANCES"
        run aws ec2 terminate-instances --region "$REGION" --instance-ids $OLD_INSTANCES >/dev/null
        run aws ec2 wait instance-terminated --region "$REGION" --instance-ids $OLD_INSTANCES
    fi
    OLD_EIPS=$(aws ec2 describe-addresses --region "$REGION" \
        --filters "Name=tag:Project,Values=$TAG_PROJECT" \
        --query 'Addresses[].AllocationId' --output text)
    for eip in $OLD_EIPS; do
        log "  releasing EIP $eip"
        run aws ec2 release-address --region "$REGION" --allocation-id "$eip" >/dev/null || true
    done
    log "  discarding state file"
    rm -f "$STATE_FILE"
fi

# --- step 2: SG ------------------------------------------------------------

SG_ID=$(state_get sg_id)
if [ -z "$SG_ID" ]; then
    SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters Name=group-name,Values=podmaker-bootstrap \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
fi
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    log "creating security group podmaker-bootstrap"
    SG_ID=$(aws ec2 create-security-group --region "$REGION" \
        --group-name podmaker-bootstrap \
        --description "PodMaker bootstrap (22/80/443)" \
        --query 'GroupId' --output text)
    run aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 22  --cidr 0.0.0.0/0
    run aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 80  --cidr 0.0.0.0/0
    run aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0
    run aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol udp --port 443 --cidr 0.0.0.0/0
else
    log "reusing security group podmaker-bootstrap ($SG_ID)"
fi
state_set sg_id "$SG_ID"

# --- step 3: SSH key pair ---------------------------------------------------

if ! aws ec2 describe-key-pairs --region "$REGION" --key-names "$SSH_KEY_NAME" >/dev/null 2>&1; then
    if [ -f "$PRIVATE_KEY" ]; then
        log "importing existing $PRIVATE_KEY as '$SSH_KEY_NAME'"
        PUB=$(ssh-keygen -y -f "$PRIVATE_KEY")
        run aws ec2 import-key-pair --region "$REGION" --key-name "$SSH_KEY_NAME" \
            --public-key-material "$(printf '%s' "$PUB" | base64)"
    else
        log "creating new key pair '$SSH_KEY_NAME' (private key → $PRIVATE_KEY)"
        umask 077
        aws ec2 create-key-pair --region "$REGION" --key-name "$SSH_KEY_NAME" \
            --query 'KeyMaterial' --output text > "$PRIVATE_KEY"
        chmod 0600 "$PRIVATE_KEY"
    fi
else
    log "reusing AWS key pair '$SSH_KEY_NAME'"
    [ -f "$PRIVATE_KEY" ] || die "AWS has key '$SSH_KEY_NAME' but $PRIVATE_KEY missing locally — pass --reset-state and rerun, or import the matching .pem"
fi
state_set key_name "$SSH_KEY_NAME"

# --- step 4: EC2 ------------------------------------------------------------

INSTANCE_ID=$(state_get instance_id)
INSTANCE_STATE=""
if [ -n "$INSTANCE_ID" ]; then
    INSTANCE_STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "none")
fi

case "$INSTANCE_STATE" in
    running)
        log "reusing instance $INSTANCE_ID (running)"
        ;;
    pending)
        log "waiting for instance $INSTANCE_ID (pending → running)"
        aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
        ;;
    "")
        log "no instance in state — provisioning new one"
        INSTANCE_ID=""
        ;;
    *)
        warn "instance $INSTANCE_ID is in state '$INSTANCE_STATE' — provisioning a new one"
        INSTANCE_ID=""
        ;;
esac

if [ -z "$INSTANCE_ID" ]; then
    AMI_PARAM="/aws/service/canonical/ubuntu/server/22.04/stable/current/arm64/hvm/ebs-gp2/ami-id"
    log "resolving Ubuntu 22.04 arm64 AMI ($AMI_PARAM)"
    AMI_ID=$(aws ssm get-parameter --region "$REGION" --name "$AMI_PARAM" \
        --query 'Parameter.Value' --output text)
    [ -n "$AMI_ID" ] && [ "$AMI_ID" != "None" ] || die "AMI resolve failed"

    # Optional: orchestrator's SSH pubkey for passwordless inbound
    # access (used by RestartStatelessFleet / MigrateTemporal /
    # MigrateNats / MigrateStepCa). Set PODMAKER_ORCH_SSH_PUBKEY to
    # an `ssh-ed25519 …` string before running this script.
    ORCH_PUBKEY="${PODMAKER_ORCH_SSH_PUBKEY:-}"
    ORCH_AUTHORIZED_LINE=""
    if [ -n "$ORCH_PUBKEY" ]; then
        ORCH_AUTHORIZED_LINE="  - \"install -m 0700 -o ubuntu -g ubuntu -d /home/ubuntu/.ssh\""
        ORCH_AUTHORIZED_LINE+=$'\n'"  - \"printf '%s\\\\n' '$ORCH_PUBKEY' >> /home/ubuntu/.ssh/authorized_keys\""
        ORCH_AUTHORIZED_LINE+=$'\n'"  - \"chmod 0600 /home/ubuntu/.ssh/authorized_keys\""
        ORCH_AUTHORIZED_LINE+=$'\n'"  - \"chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys\""
    fi

    USER_DATA=$(cat <<CLOUD_INIT
#cloud-config
package_update: true
packages:
  - curl
  - ca-certificates
  - rsync
runcmd:
  - "curl -fsSL https://get.docker.com | sh"
  - "systemctl enable --now docker"
  - "usermod -aG docker ubuntu"
  - "printf 'ubuntu ALL=(ALL) NOPASSWD: SETENV: ALL\\\\n' > /etc/sudoers.d/90-podmaker-setenv"
  - "printf 'ubuntu ALL=(ALL) NOPASSWD: /usr/bin/docker, /usr/bin/rsync, /usr/local/bin/docker, /usr/local/bin/podmaker-restart\\\\n' > /etc/sudoers.d/91-podmaker-orchestrator"
  - "chmod 0440 /etc/sudoers.d/90-podmaker-setenv /etc/sudoers.d/91-podmaker-orchestrator"
  - "install -d -m 0755 /opt/podmaker-src /opt/podmaker"
${ORCH_AUTHORIZED_LINE}
  - "touch /var/run/podmaker-ready"
CLOUD_INIT
)

    log "launching EC2 ($INSTANCE_TYPE / $DISK_GIB GB / $AMI_ID)"
    INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$SSH_KEY_NAME" \
        --security-group-ids "$SG_ID" \
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$DISK_GIB,VolumeType=gp3,DeleteOnTermination=true}" \
        --user-data "$USER_DATA" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_PROJECT-cp},{Key=Project,Value=$TAG_PROJECT},{Key=Role,Value=bootstrap}]" \
        --query 'Instances[0].InstanceId' --output text)
    log "instance $INSTANCE_ID — waiting until 'running'"
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
fi
state_set instance_id "$INSTANCE_ID"

# --- step 5: EIP ------------------------------------------------------------

EIP_ALLOC=$(state_get eip_alloc_id)
PUBLIC_IP=""
if [ -n "$EIP_ALLOC" ]; then
    EIP_INSTANCE=$(aws ec2 describe-addresses --region "$REGION" \
        --allocation-ids "$EIP_ALLOC" --query 'Addresses[0].InstanceId' --output text 2>/dev/null || echo "")
    PUBLIC_IP=$(aws ec2 describe-addresses --region "$REGION" \
        --allocation-ids "$EIP_ALLOC" --query 'Addresses[0].PublicIp' --output text 2>/dev/null || echo "")
fi

if [ -z "$EIP_ALLOC" ] || [ "$EIP_INSTANCE" != "$INSTANCE_ID" ]; then
    log "allocating + associating Elastic IP"
    EIP_ALLOC=$(aws ec2 allocate-address --region "$REGION" --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$TAG_PROJECT-cp},{Key=Project,Value=$TAG_PROJECT}]" \
        --query 'AllocationId' --output text)
    aws ec2 associate-address --region "$REGION" \
        --instance-id "$INSTANCE_ID" --allocation-id "$EIP_ALLOC" >/dev/null
    PUBLIC_IP=$(aws ec2 describe-addresses --region "$REGION" \
        --allocation-ids "$EIP_ALLOC" --query 'Addresses[0].PublicIp' --output text)
fi
state_set eip_alloc_id "$EIP_ALLOC"
state_set public_ip "$PUBLIC_IP"
log "public IP $PUBLIC_IP"

# --- step 6: SSH + cloud-init wait -----------------------------------------

log "waiting for SSH on $PUBLIC_IP:22 (up to 5 min)"
SSH_OPTS="-i $PRIVATE_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
for i in $(seq 1 60); do
    if ssh $SSH_OPTS -o BatchMode=yes ubuntu@"$PUBLIC_IP" \
           'test -f /var/run/podmaker-ready && command -v docker >/dev/null' 2>/dev/null; then
        log "SSH up + cloud-init done"
        break
    fi
    sleep 5
    [ "$i" = "60" ] && die "SSH/cloud-init never finished (timeout)"
done

# --- step 7: rsync ----------------------------------------------------------

log "rsync bootstrap bundle"
( cd "$ROOT" && rsync -azR -e "ssh $SSH_OPTS" --delete \
    deploy/docker-compose.prod.yml \
    deploy/docker-compose.bootstrap.yml \
    deploy/caddy \
    deploy/bootstrap-templates \
    scripts/bootstrap \
    infra/vault/openbao \
    infra/dev/nats \
    infra/dev/zot \
    infra/dev/temporal \
    tiers \
    ubuntu@"$PUBLIC_IP":/tmp/podmaker-src/ )

ssh $SSH_OPTS ubuntu@"$PUBLIC_IP" \
    'sudo rm -rf /opt/podmaker-src && sudo mv /tmp/podmaker-src /opt/podmaker-src'

# --- step 8: install -------------------------------------------------------

if [ "$SKIP_INSTALL" = "1" ]; then
    log "--skip-install: leaving stack untouched"
elif [ "$REINSTALL" = "1" ] || [ "$(state_get installed)" != "1" ]; then
    log "running install-podmaker.sh on host (tier=$TIER, mode=prod)"
    ssh $SSH_OPTS ubuntu@"$PUBLIC_IP" "sudo bash -c '
        set -e
        export PODMAKER_SOURCE_BASE=file:///opt/podmaker-src
        export PODMAKER_GHCR_USERNAME=$GHCR_USERNAME
        export PODMAKER_GHCR_TOKEN=\"$GHCR_PAT\"
        export PODMAKER_IMAGE_REGISTRY=$IMAGE_REGISTRY
        /opt/podmaker-src/scripts/bootstrap/install-podmaker.sh \
            --domain $DOMAIN --email $EMAIL \
            --tier $TIER --mode prod --noninteractive
    '"
    state_set installed 1
else
    log "skipping install (state says installed; pass --reinstall to force)"
fi

# --- step 9: Cloudflare DNS upsert -----------------------------------------

if [ "$SKIP_DNS" = "0" ]; then
    log "Cloudflare DNS upsert on $ZONE → $PUBLIC_IP"
    bash "$ROOT/scripts/bootstrap/cloudflare-dns-bulk.sh" --zone "$ZONE" --ip "$PUBLIC_IP"
fi

# --- summary ----------------------------------------------------------------

cat <<TXT

\033[1;32m✓ Tier-1 deploy complete.\033[0m

  Instance     ${INSTANCE_ID} (${INSTANCE_TYPE}, ${REGION})
  Public IP    ${PUBLIC_IP}  (Elastic IP ${EIP_ALLOC})
  Panel        https://${DOMAIN}
  Setup wiz    https://${DOMAIN}/setup
  Apex site    https://${ZONE}
  State file   ${STATE_FILE}

DNS propagation: dig +short @1.1.1.1 ${DOMAIN}

Tear everything down later:
  $0 --teardown --domain ${DOMAIN} --email ${EMAIL} --region ${REGION}

Resume after a failure (no reprovision):
  $0 --domain ${DOMAIN} --email ${EMAIL} --image-registry ${IMAGE_REGISTRY}
TXT
