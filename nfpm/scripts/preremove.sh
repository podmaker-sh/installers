#!/bin/sh
set -eu
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop    podmaker-vault-bridge 2>/dev/null || true
    systemctl disable podmaker-vault-bridge 2>/dev/null || true
fi
