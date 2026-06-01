# PodMaker installers

Customer-facing install scripts + service unit templates
for the PodMaker vault-bridge-agent.

## Trees

| Path | Use |
|------|-----|
| bootstrap/ | One-liner installer scripts (curl-pipe-sh) |
| systemd/   | Linux systemd unit + env templates |
| launchd/   | macOS launchd plist |
| windows/   | WiX MSI source + NSSM PS1 install script |
| nfpm/      | .deb + .rpm package config + scripts |
| homebrew/  | Source-of-truth Formula (auto-mirrored to the tap) |
| proxy/     | Front-proxy mTLS templates (Nginx, Caddy) |
| bin/       | Maintenance scripts (CA backup, …) |

Auto-synced from the private monorepo by
`publish-installers.yml`. File issues / PRs here — they
are forwarded to the monorepo by maintainers.

## Quick start

```sh
curl -fsSL https://app.podmaker.sh/install/vault-bridge | sh
```
