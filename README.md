# 🌵 Project Caktus

**One old laptop. Zero cost. Publicly accessible from anywhere.**

Turn any laptop into a self-hosted server — no VPS, no domain purchase, no port forwarding. Uses [ngrok](https://ngrok.com) to tunnel through CG-NAT and expose Docker services to the internet with free HTTPS.

## Architecture

```
Internet → ngrok Edge (HTTPS) → caktus-ngrok → caktus-nginx :80 → Docker containers
```

Everything runs on your laptop. ngrok creates an outbound tunnel — no inbound ports needed.

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/your-user/caktus.git && cd caktus

# 2. Run laptop setup (installs Docker, disables sleep, configures firewall)
bash scripts/setup-laptop.sh

# 3. Sign up for ngrok (free — dashboard.ngrok.com)
#    Copy your authtoken and create a free static domain

# 4. Configure environment
cp .env.example .env
nano .env   # paste NGROK_AUTHTOKEN and NGROK_DOMAIN

# 5. Start everything
docker compose up -d

# 6. That's it!
# Local:  http://localhost
# Public: https://your-domain.ngrok-free.app
```

## Services

| Service | Container | Description |
|---|---|---|
| **Landing Page** | `caktus-landing` | Project showcase at the root URL |
| **Hello World** | `caktus-hello` | Smoke test — if it loads, everything works |
| **Portainer** | `caktus-portainer` | Docker management UI |
| **Uptime Kuma** | `caktus-uptime` | Monitoring & status page |
| **ngrok** | `caktus-ngrok` | Public HTTPS tunnel |
| **nginx** | `caktus-nginx` | Reverse proxy, routes by Host header |

## Adding Your Own Apps

```bash
bash scripts/add-app.sh myapp 3000 myimage:tag
```

This automatically:
1. Adds the service to `docker-compose.yml`
2. Adds an nginx server block to `nginx/nginx.conf`
3. Starts the container and reloads nginx

## Scripts

| Script | Purpose |
|---|---|
| `scripts/setup-laptop.sh` | One-time laptop setup |
| `scripts/add-app.sh` | Deploy a new app (one command) |
| `scripts/health-check.sh` | Check all services, tunnel, disk, memory |
| `scripts/logs.sh` | Pretty log viewer for all services |
| `scripts/backup.sh` | Backup volumes & config (auto-prune) |

## Stack

- **[ngrok](https://ngrok.com)** — Secure tunnel, bypasses CG-NAT, free HTTPS
- **[nginx](https://nginx.org)** — Reverse proxy, routes by Host header
- **[Docker](https://docker.com)** — Container orchestration
- **[Uptime Kuma](https://github.com/louislam/uptime-kuma)** — Self-hosted monitoring
- **[Portainer](https://portainer.io)** — Docker management UI

## Project Structure

```
caktus/
├── .env                  # Secrets (never committed)
├── .env.example          # Template for .env
├── docker-compose.yml    # All service definitions
├── nginx/
│   └── nginx.conf        # Reverse proxy routes
├── apps/
│   └── landing/          # Landing page HTML
├── scripts/
│   ├── setup-laptop.sh   # One-time setup
│   ├── add-app.sh        # Deploy new apps
│   ├── health-check.sh   # System health check
│   ├── logs.sh           # Log viewer
│   └── backup.sh         # Backup utility
└── README.md
```

## License

MIT
