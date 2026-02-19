# 🌵 Project Caktus

> **One old laptop. One free VPS. Publicly accessible from anywhere on earth.**
> Zero cost. Zero vendor lock-in. Fully self-hosted. Fully yours.

---

## What Is This?

Project Caktus transforms a spare laptop into a production-grade personal application server that anyone on earth can reach via `https://app.caktus.duckdns.org` — from a phone, a friend's computer, or a judge's laptop at a hackathon.

The fundamental challenge: your laptop sits behind your home router which sits behind your ISP's Carrier-Grade NAT (CGNAT). You have no public IP, no router admin access, and no way to receive inbound internet connections directly.

**Caktus solves this with a free Oracle Cloud VPS acting purely as a network relay.** The VPS holds no data, runs no application logic, and is trivially replaceable. It exists only to give us a stable public IP. Every container, every byte of data, every computation lives on the laptop.

---

## Architecture

```
 USER (any device, any network)
   │
   │  https://app.caktus.duckdns.org
   ▼
 ┌──────────────────────────────────┐
 │  DuckDNS DNS                     │
 │  caktus.duckdns.org → VPS_IP    │
 └──────────────┬───────────────────┘
                │ TCP :443
                ▼
 ┌──────────────────────────────────────────┐
 │  ORACLE VPS (Always Free — $0/month)    │
 │                                          │
 │  ┌───────────────┐  ┌─────────────────┐ │
 │  │  Caddy (host) │  │ WireGuard Server│ │
 │  │  TLS terminate│  │ 10.0.0.1        │ │
 │  │  → 10.0.0.2:80│  │ UDP :51820      │ │
 │  └───────────────┘  └─────────────────┘ │
 └───────────────────────────┬──────────────┘
                              │ WireGuard encrypted UDP tunnel
                              │ PersistentKeepalive = 25s
                              ▼
 ┌─────────────────────────────────────────────────────────┐
 │  YOUR LAPTOP  (Ubuntu 22.04)  VPN IP: 10.0.0.2         │
 │                                                          │
 │  ┌────────────────────────────────────────────────────┐ │
 │  │  Docker network: caktus-net  (172.20.0.0/16)      │ │
 │  │                                                     │ │
 │  │  caktus-caddy :80                                  │ │
 │  │    @landing  → caktus-landing:80                   │ │
 │  │    @portainer → caktus-portainer:9000              │ │
 │  │    @uptime   → caktus-uptime:3001                  │ │
 │  │    @hello    → caktus-hello:80                     │ │
 │  │    @myapp    → caktus-myapp:3000  ← your apps      │ │
 │  └────────────────────────────────────────────────────┘ │
 └─────────────────────────────────────────────────────────┘

  📱 Any phone, any network → https://app.caktus.duckdns.org ✅
```

---

## Technology Stack

| Component | Tool | Why |
|---|---|---|
| **VPN Tunnel** | WireGuard | Modern, fast, minimal. Punches through CGNAT. Curve25519 + ChaCha20. |
| **Reverse Proxy (VPS)** | Caddy v2 | Automatic wildcard TLS via DNS-01. Zero config cert renewal. |
| **Reverse Proxy (Laptop)** | Caddy v2 | Host-header routing to containers. `auto_https off` for tunnel mode. |
| **Containers** | Docker + Compose v2 | Isolated bridge network. Per-container DNS via Docker. |
| **VPS** | Oracle Cloud Always Free | Permanently free. Stable public IP. Trivially replaceable relay. |
| **Domain** | DuckDNS | Free wildcard domain. `*.caktus.duckdns.org`. DNS-01 capable. |
| **TLS Certs** | Let's Encrypt | Free. Wildcard. Auto-renewing. ACME protocol. |
| **Monitoring** | Uptime Kuma | Self-hosted status page and uptime tracking. |
| **Server OS** | Ubuntu 22.04 LTS | Stable. Long support. netplan, UFW, systemd. |

---

## Live Services

| URL | Service | Description |
|---|---|---|
| `https://caktus.duckdns.org` | Landing Page | This project showcase |
| `https://status.caktus.duckdns.org` | Uptime Kuma | Monitoring & status page |
| `https://portainer.caktus.duckdns.org` | Portainer | Docker management UI |
| `https://hello.caktus.duckdns.org` | Hello World | Smoke test app |

---

## The Packet Journey (12 Steps)

Understanding exactly what happens when you load `https://app.caktus.duckdns.org`:

```
 1.  Browser: GET https://app.caktus.duckdns.org
 2.  DNS resolver: caktus.duckdns.org → <VPS public IP>
 3.  TCP SYN to VPS:443
 4.  TLS handshake — VPS Caddy presents *.caktus.duckdns.org wildcard cert
 5.  TLS established — browser and VPS now share a symmetric session key
 6.  Browser sends HTTP GET inside TLS tunnel
 7.  VPS Caddy decrypts, reads Host header: app.caktus.duckdns.org
 8.  VPS Caddy forwards plain HTTP to 10.0.0.2:80 (laptop WireGuard IP)
 9.  WireGuard: re-encrypts with ChaCha20-Poly1305, sends UDP → laptop:51820
10.  Laptop WireGuard: decrypts, delivers to wg0 interface (10.0.0.2)
11.  Laptop Caddy: reads Host, matches @app → reverse_proxy caktus-app:3000
12.  Docker DNS: resolves caktus-app → 172.20.x.x (container IP on caktus-net)
13.  App container: processes request, returns response
14.  Response: same path in reverse
```

---

## Project Structure

```
~/caktus/
├── docker-compose.yml          All laptop Docker services
├── .env                        Secrets (never committed)
├── .env.example                Template for .env
├── .gitignore
├── CLAUDE.md                   Claude Code context file
├── README.md                   This file
│
├── caddy/
│   ├── Caddyfile               Laptop Caddy routing config
│   ├── Caddyfile.vps           VPS Caddy gateway config (template)
│   └── wg0.vps.conf            VPS WireGuard config (template)
│
├── apps/
│   ├── landing/
│   │   └── index.html          Project landing page
│   └── <appname>/              Per-app files / bind-mount data
│
├── scripts/
│   ├── setup-laptop.sh         Phase 0+4: full laptop setup
│   ├── setup-wg.sh             Phase 2: WireGuard key gen + config
│   ├── health-check.sh         System health check (8 dimensions)
│   ├── add-app.sh              Onboard new app in one command
│   ├── backup.sh               Backup volumes + config
│   └── logs.sh                 Centralized log viewer
│
├── logs/                       Script logs (backup.sh output, etc.)
│
└── docs/
    ├── runbook.md              Day-to-day operations
    ├── networking.md           Computer networking deep dive
    ├── architecture.md         System design decisions
    ├── docker.md               Docker concepts used here
    ├── wireguard.md            WireGuard protocol deep dive
    ├── caddy.md                Caddy reverse proxy deep dive
    └── tls-https.md            TLS/HTTPS and certificate deep dive
```

---

## Quick Start

### Prerequisites
- Old laptop with Ubuntu 22.04 LTS
- Oracle Cloud Always Free account (free VM)
- DuckDNS account (free domain)

### Setup (in order)

```bash
# 1. Clone / copy project to laptop
git clone <repo> ~/caktus && cd ~/caktus

# 2. Create secrets file
cp .env.example .env
nano .env   # fill in DUCKDNS_TOKEN and VPS_IP

# 3. Run laptop setup (installs Docker, UFW, fail2ban, disables sleep)
bash scripts/setup-laptop.sh

# 4. Set static LAN IP (manual — script prints instructions)
# Edit /etc/netplan/01-netcfg.yaml, then: sudo netplan apply

# 5. Generate WireGuard keys + configs for both machines
bash scripts/setup-wg.sh

# 6. On VPS: install WireGuard, copy config, start tunnel
# (script prints exact commands to run on VPS)

# 7. On VPS: install Caddy with DuckDNS plugin, set up gateway
# See docs/caddy.md or scripts/setup-wg.sh output

# 8. Start all Docker services
docker compose up -d

# 9. Verify everything
bash scripts/health-check.sh
```

---

## Adding a New App

```bash
# One command — new app live in 30 seconds
bash scripts/add-app.sh <name> <port> <image:tag>

# Example:
bash scripts/add-app.sh notes 3000 nickel-notes:latest
# → Live at https://notes.caktus.duckdns.org
```

What this does internally:
1. Appends service block to `docker-compose.yml`
2. Appends 3-line route to `caddy/Caddyfile`
3. Runs `docker compose up -d <app>`
4. Reloads Caddy config (zero downtime)

---

## Key Commands

```bash
# Start everything
docker compose up -d

# Restart a service
docker compose restart <service>

# Live logs
bash scripts/logs.sh -f

# Logs for one service
bash scripts/logs.sh caddy

# Health check
bash scripts/health-check.sh

# Reload Caddy routing (after editing Caddyfile)
docker exec caktus-caddy caddy reload --config /etc/caddy/Caddyfile

# WireGuard status
sudo wg show

# Fix 80% of all issues
sudo systemctl restart wg-quick@wg0

# Backup everything
bash scripts/backup.sh
```

---

## Security Model

| Layer | Mechanism |
|---|---|
| **Transport** | WireGuard (ChaCha20-Poly1305) + TLS 1.3 (double-encrypted in tunnel) |
| **Public exposure** | Only VPS ports 80, 443, 51820 are open. Laptop has no open ports. |
| **Container isolation** | No container exposes host ports except `caktus-caddy`. All internal. |
| **SSH** | Key-only auth. Password auth disabled. fail2ban active. |
| **Secrets** | `.env` file, `chmod 600`, never committed to git. |
| **OS** | UFW firewall. Unattended security upgrades. |
| **WireGuard keys** | `chmod 600 /etc/wireguard/*.key`. Never transferred over network. |

---

## Deep Dive Documentation

For detailed understanding of every layer:

| Doc | Contents |
|---|---|
| [`docs/networking.md`](docs/networking.md) | CGNAT, NAT, DNS, TCP/IP, subnets — the full networking picture |
| [`docs/architecture.md`](docs/architecture.md) | Design decisions, trade-offs, alternatives rejected |
| [`docs/wireguard.md`](docs/wireguard.md) | WireGuard protocol, cryptography, config line-by-line |
| [`docs/caddy.md`](docs/caddy.md) | Reverse proxy, Caddyfile syntax, routing logic |
| [`docs/tls-https.md`](docs/tls-https.md) | TLS handshake, certificate chains, ACME, DNS-01 |
| [`docs/docker.md`](docs/docker.md) | Docker networks, bridge DNS, volumes, Compose |
| [`docs/runbook.md`](docs/runbook.md) | Day-to-day operations, troubleshooting, commands |

---

## Skills Demonstrated

This project touches every layer of the networking and infrastructure stack:

- **Computer Networking**: NAT traversal, CGNAT, VPN tunneling, subnetting, DNS, TCP/IP
- **Security**: Asymmetric cryptography (Curve25519), symmetric encryption (ChaCha20), TLS certificate chains, ACME protocol, firewall rules, SSH hardening
- **Linux Systems**: systemd, UFW, netplan, fail2ban, iptables, WireGuard kernel module
- **Docker**: Custom bridge networks, container DNS, bind mounts, named volumes, Compose v2
- **Infrastructure**: Reverse proxy design, host-based routing, zero-downtime config reload
- **DevOps**: Health checks, automated backups, log aggregation, monitoring (Uptime Kuma)
- **Cost Engineering**: Production-grade setup for literally $0/month

---

*Project Caktus — February 2026*
