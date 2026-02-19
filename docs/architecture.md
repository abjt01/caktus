# System Architecture Deep Dive
## How Every Piece of Caktus Fits Together

> This document explains the design decisions, trade-offs, and architectural reasoning
> behind Project Caktus. Read this to understand *why* each component exists.

---

## Table of Contents

1. [The Core Problem](#1-the-core-problem)
2. [Architectural Goals](#2-architectural-goals)
3. [High-Level Architecture](#3-high-level-architecture)
4. [The VPS Relay Pattern](#4-the-vps-relay-pattern)
5. [Why Two Caddy Instances?](#5-why-two-caddy-instances)
6. [Docker-First Design](#6-docker-first-design)
7. [Network Topology](#7-network-topology)
8. [Security Architecture](#8-security-architecture)
9. [Failure Modes & Recovery](#9-failure-modes--recovery)
10. [Alternatives Considered & Rejected](#10-alternatives-considered--rejected)
11. [Scalability & Limitations](#11-scalability--limitations)
12. [Cost Analysis](#12-cost-analysis)

---

## 1. The Core Problem

You have a laptop at home. You want to host web applications on it that anyone on earth can access via a clean URL like `https://myapp.caktus.duckdns.org`. The problem is threefold:

1. **No public IP** — your ISP uses Carrier-Grade NAT (CGNAT), giving your home router a private IP (`100.64.x.x`) that isn't reachable from the internet.
2. **No router control** — even if you had a public IP, port forwarding requires router admin access, which your ISP may not grant.
3. **Dynamic IPs** — even without CGNAT, residential IPs change periodically.

The traditional solution (rent a cloud VM, deploy your apps there) defeats the purpose: you lose data sovereignty, pay monthly fees, and depend on a vendor. Caktus rejects all three compromises.

### The Insight

You can't receive inbound connections, but you *can* make outbound connections through any NAT. WireGuard establishes an outbound UDP tunnel from your laptop to a VPS. Once the tunnel exists, traffic flows both ways — the NAT table has an entry for the return path. The VPS becomes a **dumb pipe** that relays TCP traffic through this tunnel.

---

## 2. Architectural Goals

Every design decision in Caktus optimizes for these goals, in priority order:

| Priority | Goal | What It Means |
|---|---|---|
| 1 | **Zero cost** | No monthly bills. Every component is permanently free. |
| 2 | **Zero vendor dependency** | No Cloudflare, no Tailscale, no ngrok. If a third-party dies, Caktus survives. |
| 3 | **Full data sovereignty** | All data lives on the laptop. The VPS never sees unencrypted application data. |
| 4 | **Production-grade reliability** | Health checks, auto-restart, monitoring, automated backups. |
| 5 | **Simplicity** | Any engineer can read the config and understand the full system in under an hour. |
| 6 | **Easy app onboarding** | Adding a new app = one shell command, live in 30 seconds. |

---

## 3. High-Level Architecture

```
                    ┌───────────────────────────────────────────┐
                    │              THE INTERNET                  │
                    └───────────────────┬───────────────────────┘
                                        │
                    ┌───────────────────▼───────────────────────┐
                    │            DuckDNS DNS                     │
                    │  *.caktus.duckdns.org → VPS Public IP     │
                    └───────────────────┬───────────────────────┘
                                        │ TCP :443
                    ┌───────────────────▼───────────────────────┐
                    │         ORACLE VPS ($0/month)              │
                    │                                            │
                    │  ┌──────────────┐  ┌───────────────────┐  │
                    │  │ Caddy (host) │  │ WireGuard Server  │  │
                    │  │              │  │                    │  │
                    │  │ TLS Terminate│  │ 10.0.0.1          │  │
                    │  │ *.caktus.    │  │ UDP :51820         │  │
                    │  │ duckdns.org  │  │                    │  │
                    │  │              │  │ Public Key Auth    │  │
                    │  │  → 10.0.0.2  │  │ ChaCha20-Poly1305 │  │
                    │  └──────────────┘  └───────────────────┘  │
                    │          ↓                    ↓             │
                    └──────────┼────────────────────┼────────────┘
                               │                    │
                    ═══════════╧════════════════════╧═══════════
                           WireGuard Encrypted UDP Tunnel
                         PersistentKeepalive = 25 seconds
                    ════════════════════════════════════════════
                               │                    │
                    ┌──────────┼────────────────────┼────────────┐
                    │          ↓                    ↓             │
                    │  YOUR LAPTOP (Ubuntu 22.04)                │
                    │  VPN IP: 10.0.0.2                          │
                    │  LAN IP: 192.168.1.100                     │
                    │                                            │
                    │  ┌────────────────────────────────────┐    │
                    │  │    Docker: caktus-net bridge       │    │
                    │  │    Subnet: 172.20.0.0/16           │    │
                    │  │                                     │    │
                    │  │  ┌──────────┐                      │    │
                    │  │  │ Caddy    │ :80                  │    │
                    │  │  │ (router) │                      │    │
                    │  │  └────┬─────┘                      │    │
                    │  │       │ Host-based routing          │    │
                    │  │       ├──→ caktus-landing:80        │    │
                    │  │       ├──→ caktus-portainer:9000    │    │
                    │  │       ├──→ caktus-uptime:3001       │    │
                    │  │       ├──→ caktus-hello:80          │    │
                    │  │       └──→ caktus-<your-app>:PORT   │    │
                    │  └────────────────────────────────────┘    │
                    └───────────────────────────────────────────┘
```

### Three Planes

The architecture cleanly separates into three planes:

| Plane | Where | Responsibility |
|---|---|---|
| **Public Plane** | VPS | TLS termination, wildcard cert, public IP anchor |
| **Tunnel Plane** | WireGuard | Encrypted relay between VPS and laptop |
| **Application Plane** | Laptop + Docker | App hosting, routing, monitoring, backups |

This separation means:
- The VPS knows nothing about individual apps
- Apps know nothing about the VPS or WireGuard
- Caddy (on laptop) is the only component that knows both sides

---

## 4. The VPS Relay Pattern

### Design: The VPS as a Dumb Pipe

The VPS runs exactly two services:
1. **WireGuard** — endpoint for the encrypted tunnel
2. **Caddy** — TLS termination and blind forwarding

The VPS Caddy config is 15 lines. It doesn't know which apps exist. It doesn't parse request bodies. It takes every HTTPS request for `*.caktus.duckdns.org`, unwraps TLS, and forwards the plain HTTP to `10.0.0.2:80` (the laptop's WireGuard IP). That's it.

```
VPS Caddy receives: HTTPS request for portainer.caktus.duckdns.org
VPS Caddy does:     Decrypt TLS → forward HTTP to 10.0.0.2:80
VPS Caddy knows:    Nothing about Portainer, its port, or its existence
```

### Why This Matters

- **Replaceable**: If oracle shuts down, spin up a new VPS anywhere, run 3 commands, done.
- **No data exposure**: Even if the VPS is compromised, the attacker sees encrypted WireGuard packets. Application data never touches VPS disk.
- **Stateless**: The VPS stores nothing. No database, no volumes, no config beyond the Caddyfile and WireGuard keys.
- **Minimal attack surface**: Only 3 ports open (80, 443, 51820). No app containers, no Docker socket.

### Why Not Run Apps on the VPS?

Oracle's Always Free VMs have:
- 1 OCPU (1/8 of a core, burstable)
- 1 GB RAM
- 47 GB storage

This is barely enough for a reverse proxy. Running real applications would hit resource limits immediately. The laptop (even an old one) has 4–16 GB RAM, multi-core CPU, and potentially terabytes of storage. The laptop is the compute powerhouse; the VPS is the network doorbell.

---

## 5. Why Two Caddy Instances?

This is the most common question. Why not one Caddy doing everything?

### Separation of Concerns

```
VPS Caddy                              Laptop Caddy
─────────────                          ──────────────
TLS concern                            Routing concern
Knows: wildcard domain, certs          Knows: each app, each port
Changes: never                         Changes: every time you add an app
Runs on: VPS (public IP)               Runs on: laptop (Docker)
Config: 15 lines (never changes)       Config: grows with each app
```

### Why Not One Caddy on the VPS?

If VPS Caddy did host-based routing:
1. Every new app requires SSH into VPS to edit Caddyfile
2. VPS Caddy needs to know every container name and port
3. Your Caddy config is split between two machines
4. The VPS becomes stateful (it has routing knowledge)

With the two-Caddy pattern, the VPS config is **write-once, forget forever**. All app management happens on the laptop.

### Why Not One Caddy on the Laptop?

The laptop Caddy can't do TLS:
1. It has no public IP — Let's Encrypt can't reach it for HTTP-01 challenges
2. DNS-01 challenges need the DuckDNS plugin — which requires a custom Caddy build (xcaddy)
3. Since the laptop already runs behind WireGuard, plain HTTP on `:80` suffices — TLS is handled on the VPS

The laptop Caddy runs with `auto_https off` and `admin off` — it's purely a router.

### The Flow

```
1. HTTPS arrives at VPS Caddy
2. VPS Caddy strips TLS, gets plain HTTP with Host header
3. VPS Caddy blindly forwards to 10.0.0.2:80
4. WireGuard encrypts and sends to laptop
5. Laptop Caddy reads Host header
6. Laptop Caddy routes to correct container via Docker DNS
```

The HTTP between VPS Caddy and laptop Caddy is inside a WireGuard tunnel — it's encrypted with ChaCha20-Poly1305. There is no plaintext HTTP on the public internet at any point.

---

## 6. Docker-First Design

### Why Docker?

| Without Docker | With Docker |
|---|---|
| Install each app's runtime (Node, Python, Go...) on host | `image: app:tag` — runtime included |
| Port conflicts between apps | Each container has private ports |
| App crash can affect other apps | Container isolation — kernel namespaces |
| Manual DNS between services | Docker DNS: `caktus-portainer` → `172.20.x.x` |
| Cleanup is painful | `docker compose down` — clean slate |

### The caktus-net Bridge

All containers sit on one custom bridge network (`172.20.0.0/16`). This provides:
- **Automatic DNS** — container names resolve to IPs
- **Network isolation** — containers can't reach outside networks
- **No port binding** — no container exposes host ports except Caddy

The bridge is a virtual Layer 2 switch inside the kernel. Packets between containers never leave the host — they're switched in RAM. This is faster than going through the host network stack.

### The caktus-caddy Gateway Pattern

Only `caktus-caddy` binds host ports (`80`, `443`). Every other container is invisible to the host network. This means:
- Port 9000 (Portainer) is not accessible from the LAN or internet
- Port 3001 (Uptime Kuma) is not accessible from the LAN or internet
- The only way to reach them is through Caddy → Docker DNS → container IP

This is **defense-in-depth**: even if an attacker bypasses WireGuard and reaches the laptop, they can't access any application port directly. They'd need to go through Caddy's routing rules.

### Compose Patterns

Every container follows the same pattern:
```yaml
  appname:
    image: image:tag
    container_name: caktus-appname    # predictable name for DNS
    networks:
      - caktus-net                    # on the shared bridge
    restart: unless-stopped           # auto-restart on crash/reboot
```

No `ports:` section (except Caddy). No `privileged:`. No `network_mode: host`. These constraints are deliberate — they enforce isolation.

---

## 7. Network Topology

### Three Private Networks

Caktus uses three separate private IP spaces, each for a different purpose:

```
┌──────────────────────────────────────────────────────────────┐
│                                                               │
│  192.168.1.0/24   ← Your Home LAN                            │
│  ├── 192.168.1.1   Router (gateway)                          │
│  └── 192.168.1.100 Laptop (static)                           │
│                                                               │
│  10.0.0.0/24      ← WireGuard VPN Overlay                    │
│  ├── 10.0.0.1      VPS (WireGuard server)                    │
│  └── 10.0.0.2      Laptop (WireGuard client)                 │
│                                                               │
│  172.20.0.0/16    ← Docker Bridge (caktus-net)               │
│  ├── 172.20.0.2    caktus-caddy                              │
│  ├── 172.20.0.3    caktus-portainer                          │
│  ├── 172.20.0.4    caktus-uptime                             │
│  ├── 172.20.0.5    caktus-landing                            │
│  └── 172.20.0.6+   Your app containers                      │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### Routing Decision Tree

When the laptop kernel receives a packet, it checks the destination IP:

```
Destination IP?
  │
  ├── 10.0.0.x     → Route through wg0 interface (WireGuard tunnel)
  │
  ├── 172.20.x.x   → Route through docker0/br-xxxx (Docker bridge)
  │
  ├── 192.168.1.x  → Route through eth0/wlan0 (LAN)
  │
  └── Anything else → Route through default gateway (internet)
```

These routing rules are automatically set by WireGuard (`AllowedIPs`), Docker (bridge creation), and netplan (static IP config).

### Split Tunneling

The laptop's WireGuard config specifies `AllowedIPs = 10.0.0.1/32`. This means only traffic destined for the VPS's WireGuard IP goes through the tunnel. All other internet traffic (updates, browsing, downloads) goes through the normal ISP connection. This is critical — routing all traffic through the VPS would:
1. Add latency to every connection
2. Saturate the VPS's bandwidth
3. Expose browsing history to Oracle Cloud

---

## 8. Security Architecture

### Defense-in-Depth Layers

```
Layer 1: OS-level firewall (UFW)
  │  Only ports 22, 80, 443, 51820 open
  │
Layer 2: WireGuard (Curve25519 + ChaCha20-Poly1305)
  │  Tunnel is authenticated + encrypted
  │  Only peers with known public keys can communicate
  │
Layer 3: TLS 1.3 (on VPS Caddy)
  │  Browser ↔ VPS: end-to-end encrypted
  │  Wildcard cert: *.caktus.duckdns.org
  │
Layer 4: Docker network isolation
  │  No container exposes host ports except Caddy
  │  Containers can only talk to each other on caktus-net
  │
Layer 5: SSH key-only auth + fail2ban
  │  Password authentication disabled
  │  Brute-force protection via fail2ban jails
  │
Layer 6: Secrets management
     .env file with chmod 600, never committed to git
     WireGuard private keys: chmod 600
```

### Why Double Encryption Isn't Wasteful

Traffic from browser to Caktus is encrypted twice:
1. **TLS** (browser ↔ VPS Caddy) — encrypts HTTP
2. **WireGuard** (VPS ↔ laptop) — encrypts the already-encrypted-then-decrypted HTTP

Wait — VPS Caddy decrypts TLS first, then WireGuard re-encrypts for the tunnel. So the traffic is single-encrypted at any point, but by different systems:
- Browser → VPS: TLS encrypted
- VPS → Laptop: WireGuard encrypted
- Inside Docker: plain HTTP (localhost only — never leaves the machine)

The VPS sees plaintext HTTP briefly (in RAM, never on disk), but an attacker intercepting the WireGuard tunnel sees only encrypted packets. An attacker intercepting the internet between browser and VPS sees only TLS. There's no point where an internet-positioned attacker sees plaintext.

### Threat Model

| Threat | Mitigation |
|---|---|
| VPS compromised | Attacker sees plaintext HTTP in RAM; no persistent data on VPS; rotate WireGuard keys |
| WireGuard tunnel intercepted | ChaCha20-Poly1305 — computationally infeasible to break |
| MITM between browser and VPS | TLS 1.3 with Let's Encrypt cert — browser verifies chain of trust |
| Someone scans your laptop | UFW drops everything except SSH and WireGuard; no app ports exposed |
| Container escape | Docker namespaces + no `--privileged` + no host network mode |
| DuckDNS account compromise | Attacker can redirect DNS but can't get a cert without your DuckDNS token |
| SSH brute force | Key-only auth + fail2ban auto-bans after 5 attempts |

---

## 9. Failure Modes & Recovery

### Failure Analysis

| What Fails | Impact | Detection | Recovery |
|---|---|---|---|
| **WireGuard tunnel** | All external access lost | `ping 10.0.0.1` or health check | `sudo systemctl restart wg-quick@wg0` |
| **Docker container** | Single app down | `docker compose ps` or Uptime Kuma alert | `docker compose up -d <app>` |
| **Laptop Caddy** | All apps 502 | Health check or Uptime Kuma | `docker compose restart caddy` |
| **VPS Caddy** | All external access lost | Can't reach any `*.caktus.duckdns.org` | SSH to VPS, `sudo systemctl restart caddy` |
| **DuckDNS token expires** | DNS stops updating (still works until IP changes) | Heath check DNS verification | Regenerate token on duckdns.org |
| **ISP IP changes** | DuckDNS container updates it automatically (~5 min delay) | Brief outage | Automatic |
| **Power outage** | Everything down | Physical | Plug in, `docker compose up -d`, verify WireGuard |
| **Disk full** | Containers may crash | Health check disk check | `docker image prune -f`, clear logs |

### The 80% Fix

`sudo systemctl restart wg-quick@wg0` fixes 80% of all connectivity issues. This is because:
1. NAT table entries expire → WireGuard handshake fails → restart re-establishes
2. ISP reconnects → new IP → WireGuard endpoint changes → restart picks up new endpoint
3. Kernel module glitch → restart re-initializes wg0 interface

### Monitoring

Uptime Kuma runs as a container (`caktus-uptime`) and monitors:
- External URLs (checks from the laptop side)
- Docker container health
- Response time trends

It provides a public status page at `https://status.caktus.duckdns.org` and can send alerts via Telegram, email, or webhooks.

---

## 10. Alternatives Considered & Rejected

### Cloudflare Tunnel

**What it is:** A proprietary tunnel from your origin server to Cloudflare's edge.

**Why rejected:**
- Traffic is decrypted at Cloudflare's edge servers — they can inspect every request
- Violates data sovereignty principle — you don't control the relay
- Cloudflare can rate-limit, block, or discontinue the free tier
- Creates vendor dependency — if Cloudflare bans your account, you're offline

### Tailscale

**What it is:** A zero-config WireGuard mesh network with a proprietary control plane.

**Why rejected:**
- Control plane is closed-source and runs on Tailscale's servers
- Authentication depends on Tailscale's infrastructure
- Not truly self-hosted — you rely on their coordination layer
- Free tier has device limits; business model depends on upselling

### ngrok

**What it is:** A tunneling service that gives you a public URL pointing to a local port.

**Why rejected:**
- Free tier: random URLs, rate limits, connections throttled
- Paid tier: defeats the zero-cost goal
- Single point of failure — ngrok outage = your apps offline
- Traffic passes through ngrok's infrastructure

### DDNS + Port Forwarding

**What it is:** Dynamic DNS points your domain to your router; port forwarding routes to your laptop.

**Why rejected:**
- Completely broken by CGNAT — you can't port-forward through your ISP's NAT
- Even without CGNAT, requires router admin access
- ISP can change your public IP at any time
- No wildcard TLS

### IPv6 Direct Hosting

**What it is:** Serve directly over IPv6 (which doesn't have NAT).

**Why rejected:**
- Many ISPs don't support IPv6 yet
- Many clients (corporate networks, older phones) can't reach IPv6-only servers
- No fallback for IPv4-only users
- Caktus must be universally accessible

### The Winner: WireGuard + Free VPS

WireGuard + Oracle Always Free gives us:
- ✅ Outbound UDP punches through any NAT (including CGNAT)
- ✅ Truly self-hosted — we control both endpoints
- ✅ No traffic inspection — WireGuard encrypts everything
- ✅ Zero cost — Oracle Always Free is permanent (not a trial)
- ✅ Replaceable — if Oracle dies, any free VPS works
- ✅ Wildcard TLS via DuckDNS DNS-01 challenge

---

## 11. Scalability & Limitations

### What Scales

| Dimension | Limit | Why |
|---|---|---|
| Number of apps | Practically unlimited | Each is a Docker container; laptop RAM is the constraint |
| Number of subdomains | Unlimited | Wildcard cert covers `*.caktus.duckdns.org` |
| Adding a new app | 30 seconds | `bash scripts/add-app.sh name port image` |
| Storage | Laptop disk size | Bind mounts and Docker volumes on local disk |

### What Doesn't Scale

| Dimension | Limit | Why |
|---|---|---|
| Concurrent users | ~100–500 | Limited by VPS bandwidth (50 Mbps) and laptop resources |
| Bandwidth | ~50 Mbps | Oracle Free Tier limit; also limited by home upload speed |
| Geographic latency | Single region | All traffic routes through one VPS; no CDN |
| High availability | Single point of failure | One laptop, one VPS — no redundancy |
| Team collaboration | Single admin | No multi-user management; one person's laptop |

### This Is By Design

Caktus is a **personal** application server. It's not designed to serve thousands of users or provide five-nines uptime. It's designed to:
- Host your portfolio, side projects, demos, and tools
- Be reachable from anywhere
- Cost nothing
- Teach you how the internet actually works

---

## 12. Cost Analysis

### Monthly Cost Breakdown

| Component | Cost | Notes |
|---|---|---|
| Oracle VPS | $0 | Always Free tier (permanent, not trial) |
| DuckDNS domain | $0 | Free dynamic DNS |
| Let's Encrypt certificates | $0 | Free, automated |
| WireGuard | $0 | Open-source, in-kernel |
| Docker | $0 | Open-source |
| Caddy | $0 | Open-source |
| Uptime Kuma | $0 | Open-source |
| Portainer CE | $0 | Community edition |
| Electricity | ~$3–5/month | An old laptop uses ~30–50W |
| **Total** | **~$3–5/month** | **Electricity only** |

### Compared to Alternatives

| Solution | Monthly Cost | Trade-off |
|---|---|---|
| AWS EC2 (t3.micro) | $8.50 | Vendor-locked, data on their servers |
| DigitalOcean droplet | $6 | Same as above |
| Railway / Render | $5–25 | PaaS lock-in, cold starts |
| Vercel Pro | $20 | Frontend only, vendor-dependent |
| Cloudflare Tunnel | $0 | Data passes through Cloudflare |
| **Caktus** | **$0** | **Self-hosted, self-managed, fully private** |

---

## Key Takeaways

1. **The VPS is a pipe, not a server.** All intelligence lives on the laptop.
2. **Two Caddy instances** cleanly separate TLS (VPS concern) from routing (laptop concern).
3. **Docker bridge networking** provides DNS, isolation, and port hiding in one mechanism.
4. **WireGuard + outbound UDP** bypasses CGNAT without any port forwarding.
5. **The entire system is stateless on the VPS side** — rebuild it in 10 minutes from scratch.
6. **Every component is free and open-source** — no vendor can pull the rug.
7. **Security is layered** — UFW → WireGuard → TLS → Docker isolation → SSH hardening.
8. **The architecture teaches real networking** — NAT, DNS, TLS, subnetting, VPN, reverse proxy — concepts that apply everywhere.

---

*Part of Project Caktus documentation suite*
