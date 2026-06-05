# WireGuard VPN server with HTTPS web UI

This repository deploys a self-hosted WireGuard VPN server with the wg-easy web UI,
nginx-proxy, and automatic Let's Encrypt certificates.

The default stack is intentionally small and reproducible:

- pinned production images, no floating `latest` tags;
- a static, always-valid `compose.yml`;
- configuration through `.env`, not by mutating YAML;
- no unattended Watchtower upgrades;
- no destructive rollback that deletes compose files or volumes;
- wg-easy v15 unattended setup for the first admin user;
- the initial admin password is removed from `.env` after the first successful start.

## Components

- `nginxproxy/nginx-proxy:1.11.0`
- `nginxproxy/acme-companion:2.6.3`
- `ghcr.io/wg-easy/wg-easy:15`
- optional Beszel monitoring profile: `henrygd/beszel:v0.18.7`

## Requirements

- Debian or Ubuntu with `apt`
- root access
- public IPv4 address
- a domain or subdomain with an A record pointing to the server
- open inbound TCP `80` and `443`
- open inbound UDP WireGuard port shown by the installer

## Install

Clone the repository and run:

```sh
chmod +x menu.sh
sudo ./menu.sh
```

Choose `1. Install or reconfigure VPN`.

The installer asks for:

- WireGuard web UI domain, for example `vpn.example.com`;
- Let's Encrypt email;
- initial wg-easy admin username;
- initial wg-easy admin password.

The script detects the public IPv4 address, validates DNS, chooses a high UDP port,
starts the stack, and prints the final URL and WireGuard port.

## Operations

Show status:

```sh
sudo ./menu.sh
```

Choose `2. Show status`.

Update within the pinned image lines:

```sh
sudo ./menu.sh
```

Choose `4. Pull pinned images and restart`.

Reset the wg-easy admin password:

```sh
sudo ./menu.sh
```

Choose `5. Reset WireGuard admin password`.

## Optional Monitoring

Beszel is included as an optional Compose profile, because the official Beszel flow
requires creating the hub user and adding a system/token from the web UI.

To enable it, fill these values in `.env`:

```dotenv
BESZEL_DOMAIN=monitoring.example.com
BESZEL_AGENT_TOKEN=...
BESZEL_AGENT_KEY=...
```

Then run:

```sh
docker compose --env-file .env -f compose.yml --profile monitoring up -d
```

## Notes

- `.env` is ignored by git and has mode `600` after the installer writes it.
- Backups created by the menu are stored in `backups/`.
- Do not use Watchtower or floating `latest` tags for this stack unless you are
  ready to debug breaking changes after an automatic update.

## Official References

- wg-easy documentation: https://wg-easy.github.io/wg-easy/latest/
- wg-easy CLI password reset: https://wg-easy.github.io/wg-easy/latest/guides/cli/
- nginx-proxy documentation: https://github.com/nginx-proxy/nginx-proxy
- acme-companion documentation: https://github.com/nginx-proxy/acme-companion
- Docker Compose file reference: https://docs.docker.com/reference/compose-file/
- Beszel documentation: https://www.beszel.dev/guide/getting-started

## License

MIT
