#!/bin/sh
set -eu

# Create the `bridge` service user + group if missing.
if ! getent group bridge >/dev/null 2>&1; then
    groupadd --system bridge
fi
if ! getent passwd bridge >/dev/null 2>&1; then
    useradd --system --gid bridge --shell /usr/sbin/nologin \
            --home-dir /var/lib/podmaker-bridge --create-home \
            --comment "PodMaker Vault Bridge" bridge
fi

# Persistent cert dir owned by the service user.
install -d -o bridge -g bridge -m 0700 /var/lib/podmaker-bridge

# Drop the operator a starter env file. We do NOT overwrite if it
# already exists — preserve the customer's bridge id/token.
if [ ! -f /etc/podmaker-vault-bridge.env ]; then
    cp /etc/podmaker-vault-bridge.env.example /etc/podmaker-vault-bridge.env
    chmod 0600 /etc/podmaker-vault-bridge.env
    chown root:bridge /etc/podmaker-vault-bridge.env
fi

# Register the unit. The operator still enables + starts it after
# editing the env file so we never auto-launch with placeholder
# bridge ids.
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    cat <<TXT
podmaker-vault-bridge installed. Next steps:

    sudo $EDITOR /etc/podmaker-vault-bridge.env   # set BRIDGE_ID + TOKEN + CP_URL
    sudo systemctl enable --now podmaker-vault-bridge

Logs:
    journalctl -u podmaker-vault-bridge -f
TXT
fi
