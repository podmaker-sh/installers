#!/bin/sh
set -eu

# Daemon-reload is harmless on upgrade as well as remove.
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

# We deliberately leave /etc/podmaker-vault-bridge.env and the
# /var/lib/podmaker-bridge cert bundle in place on remove. Operators
# wipe those by hand if they really mean to retire the bridge:
#
#     sudo rm -rf /var/lib/podmaker-bridge /etc/podmaker-vault-bridge.env
#     sudo userdel bridge
#     sudo groupdel bridge
