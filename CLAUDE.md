# 🌵 CAKTUS — Claude Code Master Context

> This file is automatically loaded by Claude Code at every session start.
> It gives Claude the full context of Project Caktus so you never repeat yourself.
> Keep it under 300 lines. Pointers > copies. Precision > verbosity.

---

## 📌 Project Identity

**Name:** Project Caktus
**Goal:** Self-hosted, Docker-based personal application server — publicly accessible
from anywhere, zero cost, zero vendor dependency, fully under owner's control.
**Tagline:** One laptop. One server. Fully free. Fully mine.
**Status:** Active build — core stack running.

---

## 🖥️ Environment

| Property | Value |
|---|---|
| Server machine | Old laptop running Ubuntu 22.04 LTS |
| LAN IP (static) | `192.168.1.100` (set via netplan) |
| Tunnel provider | ngrok free tier (static domain) |
| ngrok domain | Set in `.env` as `NGROK_DOMAIN` |
| Working directory | `~/caktus/` |
| Shell | bash |
| Container runtime | Docker Engine + Docker Compose v2 (plugin) |

---

## 🏗️ Architecture (Mental Model)

```
USER (anywhere)
  │ https://<ngrok-domain>.ngrok-free.app
  ▼
[ngrok Edge] — Cloudflare-grade TLS termination
  │ (outbound tunnel — no inbound ports needed)
  ▼
[caktus-ngrok container] → [caktus-nginx:80]
  ▼
[Laptop: nginx] — routes by Host header → Docker containers
  └── container name resolution via caktus-net bridge
```

**Key principle:** ngrok is the pipe. All compute, data, and apps live on the laptop.
Management tools (Portainer, Uptime Kuma) are **intentionally LAN-only** — not exposed publicly.

**Routing model:**
- Public traffic: all comes in on one ngrok domain → default_server → landing page.
  To expose a user app publicly, use path-based `location` blocks in the default server.
- Local traffic: `.caktus.local` subdomains via `/etc/hosts` on the laptop.

---

## 📁 Project File Structure

```
~/caktus/
├── docker-compose.yml          ← all laptop Docker services
├── .env                         ← secrets (NGROK_AUTHTOKEN, NGROK_DOMAIN) — never commit
├── .env.example                 ← template — safe to commit
├── .gitignore
├── CLAUDE.md                    ← this file
├── nginx/
│   └── nginx.conf              ← laptop routing rules
├── apps/
│   └── landing/
│       └── index.html          ← landing page (public)
├── scripts/
│   ├── setup-laptop.sh         ← one-time laptop setup
│   ├── health-check.sh         ← system health check
│   ├── add-app.sh              ← automates new app onboarding
│   ├── remove-app.sh           ← removes an app cleanly
│   ├── backup.sh               ← backs up volumes + config
│   └── logs.sh                 ← pretty log viewer
└── docs/
    └── runbook.md              ← operational notes
```

---

## 🔑 Secrets & Environment

All secrets live in `~/caktus/.env`. Never hardcode them. Never commit `.env`.

```bash
NGROK_AUTHTOKEN=<from dashboard.ngrok.com → Auth → Tokens>
NGROK_DOMAIN=<your-static-domain.ngrok-free.app>
```

Reference in `docker-compose.yml` via `${NGROK_AUTHTOKEN}` syntax.

---

## 🐳 Docker Conventions

**Network:** All app containers connect to `caktus-net` (bridge, subnet `172.20.0.0/16`).
**Naming:** All containers prefixed `caktus-` (e.g. `caktus-nginx`, `caktus-myapp`).
**Port binding:** Only `caktus-nginx` exposes host ports (`:80`). All other containers have NO host port binding.
**Restart policy:** Always `restart: unless-stopped`.
**Logging:** All services use `json-file` driver with `max-size: 10m`, `max-file: 3`.
**Compose command:** Always use `docker compose` (v2 plugin), not `docker-compose` (v1).

### Adding a New App (The Caktus Pattern)

**Automated (preferred):**
```bash
bash scripts/add-app.sh myapp 3000 myimage:tag
```

**Manual Step 1 — docker-compose.yml:**
```yaml
myapp:
  image: myimage:tag
  container_name: caktus-myapp
  networks:
    - caktus-net
  restart: unless-stopped
  logging: *default-logging
```

**Manual Step 2 — nginx/nginx.conf (LAN local access, before the ADD NEW APP marker):**
```nginx
server {
    listen 80;
    server_name myapp.caktus.local;
    location / { proxy_pass http://caktus-myapp:3000; }
}
```

**Manual Step 3 — Apply:**
```bash
cd ~/caktus && docker compose up -d
docker compose restart nginx
```

### Removing an App
```bash
bash scripts/remove-app.sh myapp
```

---

## 🌐 nginx Configuration Rules

**Laptop nginx.conf** (`~/caktus/nginx/nginx.conf`):
- TLS is handled by ngrok — nginx only speaks plain HTTP on port 80.
- LAN routing: separate `server {}` blocks with `server_name <app>.caktus.local`.
- Public routing: all ngrok traffic hits the `default_server` block → landing page.
  To expose an app publicly, add a `location /myapp` block in the default server.
- Upstream is always container name + internal port (Docker DNS handles resolution).
- WebSocket headers are set globally (harmless when unused).
- New app routes go **above** the `# ── ADD NEW APP ROUTES ABOVE THIS LINE` marker.

---

## 🔧 Key Commands (Reference)

```bash
# Start / restart all services
cd ~/caktus && docker compose up -d

# Check service status
docker compose ps

# Live logs (all services)
bash scripts/logs.sh -f

# Logs for specific service
bash scripts/logs.sh nginx

# Reload nginx config (after nginx.conf edit)
docker compose restart nginx

# Full health check
bash ~/caktus/scripts/health-check.sh

# Add a new app (automated)
bash scripts/add-app.sh <appname> <port> <image:tag>

# Remove an app
bash scripts/remove-app.sh <appname>

# Manual backup
bash scripts/backup.sh

# ngrok tunnel status
docker logs caktus-ngrok

# Container health
docker inspect --format='{{.State.Health.Status}}' caktus-nginx
```

---

## 🏁 Running Services

| Service | Container | Access |
|---|---|---|
| Landing page | `caktus-landing` | Public (default ngrok URL) |
| nginx | `caktus-nginx` | Internal router |
| ngrok | `caktus-ngrok` | Tunnel |
| Portainer | `caktus-portainer` | LAN: `portainer.caktus.local` |
| Uptime Kuma | `caktus-uptime` | LAN: `status.caktus.local` |
| Hello (smoke test) | `caktus-hello` | LAN: `hello.caktus.local` |

---

## 🛡️ Security Constraints

- SSH password auth must be disabled (`PasswordAuthentication no` in `/etc/ssh/sshd_config`)
- Docker socket: `chmod 660 /var/run/docker.sock`
- `.env` must be in `.gitignore`
- Fail2ban must be installed and running
- Unattended security upgrades must be enabled
- Never expose app container ports directly to host — all traffic through nginx
- Management tools (Portainer, Uptime Kuma) must NOT be publicly accessible via ngrok

---

## 🚨 Troubleshooting Quick Reference

| Symptom | First fix |
|---|---|
| URL connection refused | `docker compose restart nginx` |
| 502 Bad Gateway | `docker compose up -d` then `docker compose logs <service>` |
| ngrok tunnel dead | `docker compose restart ngrok` then check `docker logs caktus-ngrok` |
| App not routing locally | Check `/etc/hosts` has `127.0.0.1 <app>.caktus.local` |
| Disk full | `docker system prune` — then check `~/caktus/backups/` for old backups |
| Everything broken | `docker compose down && docker compose up -d` |

---

## 📐 Constraints & Preferences

- **Never use `docker-compose` (v1 hyphen syntax)** — always `docker compose`
- **Never suggest paid services** — entire stack must be $0
- **Prefer pointers over full file content** when referencing existing project files
- **Scripts go in `~/caktus/scripts/`** — not scattered in root
- **All containers on `caktus-net`** — no exceptions
- **All services include log rotation** (`logging: *default-logging`)
- When writing shell scripts, use `#!/bin/bash` and `set -e`
- Prefer `docker compose` health checks over manual polling scripts

---

## 🗺️ Related Docs

- Operational runbook: `~/caktus/docs/runbook.md`
- Per-app notes: `~/caktus/apps/<appname>/README.md`

---

*Last updated: February 2026 | Project Caktus v2.1 (nginx architecture)*
