# 🌵 Project Caktus

> **Hardware redemption arc. Deploy. Survive. Repeat.**

Turn any laptop into a self-hosted server — no VPS, no domain purchase, no port
forwarding. Uses [ngrok](https://ngrok.com) to tunnel through CG-NAT and expose
anything you deploy to the internet with free HTTPS.

Project Caktus is a zero-cost, Docker-based personal infrastructure stack designed to run entirely on your own hardware. All compute, storage, and applications stay on your machine, while a secure outbound tunnel makes them publicly accessible from anywhere. No cloud dependency. No vendor lock-in. 
Just a controlled, reproducible setup that turns spare hardware into reliable, internet-facing infrastructure.

<img width="2544" height="1500" alt="image" src="https://github.com/user-attachments/assets/e6c8b6ac-d1b2-45e9-879e-e4ae3ae96882" />

## Architecture

```
Internet → ngrok Edge (HTTPS) → caktus-ngrok → caktus-nginx :80 → your apps
```

Everything runs on your laptop. ngrok makes an outbound connection — no inbound
ports, no static IP, no router config needed.

## Quick Start

```bash
git clone https://github.com/your-user/caktus.git && cd caktus

bash scripts/setup-laptop.sh        # installs Docker, disables sleep, firewall

cp .env.example .env
nano .env                            # paste NGROK_AUTHTOKEN and NGROK_DOMAIN

docker compose up -d --build

# Local:  http://localhost
# Public: https://your-domain.ngrok-free.app
```

Get your free authtoken and static domain at [dashboard.ngrok.com](https://dashboard.ngrok.com).

## Deploy an App

Open your public URL — you'll see the deploy terminal. Fill in app name, port,
image or Dockerfile, env vars. Click deploy. Get a public URL in seconds.

```
https://your-domain.ngrok-free.app/apps/{name}/
```

Port must match what your app listens on — `3000` for Next.js, `8000` for
FastAPI, `80` for nginx.

<img width="2940" height="2145" alt="image" src="https://github.com/user-attachments/assets/eb7529aa-07b6-4c3d-944e-d89f061e4205" />

## Services

| Service | Container | Access |
|---|---|---|
| **Dashboard** | `caktus-dashboard` | Public — `/` |
| **nginx** | `caktus-nginx` | Internal router |
| **ngrok** | `caktus-ngrok` | Outbound tunnel |
| **Portainer** | `caktus-portainer` | LAN — `portainer.caktus.local` |
| **Uptime Kuma** | `caktus-uptime` | LAN — `status.caktus.local` |
| **Hello World** | `caktus-hello` | LAN — `hello.caktus.local` |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/setup-laptop.sh` | One-time setup |
| `scripts/health-check.sh` | Services, tunnel, disk, memory |
| `scripts/logs.sh` | Log viewer for all services |
| `scripts/backup.sh` | Backup volumes and config |

## Stack

- **[ngrok](https://ngrok.com)** — Tunnel, bypasses CG-NAT, free HTTPS
- **[nginx](https://nginx.org)** — Reverse proxy, path-based routing
- **[FastAPI](https://fastapi.tiangolo.com)** — Dashboard backend
- **[Docker](https://docker.com)** — Container orchestration
- **[Uptime Kuma](https://github.com/louislam/uptime-kuma)** — Monitoring
- **[Portainer](https://portainer.io)** — Docker UI

## Structure

```
caktus/
├── docker-compose.yml        # All service orchestration
├── .env.example              # Environment template (NGROK_DOMAIN, tokens)
├── nginx/                    # Internal reverse proxy (public + LAN routing)
│   └── nginx.conf
├── caddy/                    # Local domain handling (*.caktus.local)
│   └── Caddyfile
├── apps/                     # User applications
│   └── dashboard/            # Public control interface (FastAPI)
├── scripts/                  # Automation & lifecycle management
│   ├── setup-laptop.sh
│   ├── add-app.sh
│   ├── remove-app.sh
│   └── backup.sh
└── docs/                     # Operational notes & runbook
```
