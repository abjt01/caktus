# Caddy Reverse Proxy Deep Dive
## How Caktus Routes Traffic From the Internet to Your Containers

> Caddy is the traffic controller of Caktus — one instance on the VPS handles TLS,
> another on the laptop handles app routing. This doc explains both in detail.

---

## Table of Contents

1. [What Is a Reverse Proxy?](#1-what-is-a-reverse-proxy)
2. [Why Caddy Over Nginx or Traefik](#2-why-caddy-over-nginx-or-traefik)
3. [The Dual-Caddy Architecture](#3-the-dual-caddy-architecture)
4. [VPS Caddyfile Explained](#4-vps-caddyfile-explained)
5. [Laptop Caddyfile Explained](#5-laptop-caddyfile-explained)
6. [Host-Based Routing (Named Matchers)](#6-host-based-routing-named-matchers)
7. [How Caddy Handles WebSocket, HTTP/2, and gRPC](#7-how-caddy-handles-websocket-http2-and-grpc)
8. [The Wildcard TLS Pattern](#8-the-wildcard-tls-pattern)
9. [Header Forwarding & Preserving Client IPs](#9-header-forwarding--preserving-client-ips)
10. [Zero-Downtime Config Reloads](#10-zero-downtime-config-reloads)
11. [Adding a New App Route](#11-adding-a-new-app-route)
12. [Caddy in Docker vs Host Install](#12-caddy-in-docker-vs-host-install)
13. [Troubleshooting Caddy](#13-troubleshooting-caddy)

---

## 1. What Is a Reverse Proxy?

A **reverse proxy** sits between clients and backend servers. Clients don't connect to backends directly — they all connect to the proxy, which decides where to forward each request.

### Forward Proxy vs Reverse Proxy

```
Forward Proxy (e.g., corporate proxy):
  Client → Proxy → Internet
  Client knows about the proxy; server doesn't.

Reverse Proxy (e.g., Caddy in Caktus):
  Internet → Proxy → Backend Server
  Server knows about the proxy; client doesn't.
```

In Caktus, the user has no idea they're talking to Caddy. They think they're talking to Portainer or Uptime Kuma directly. Caddy is invisible.

### What a Reverse Proxy Provides

| Feature | How Caktus Uses It |
|---|---|
| **TLS termination** | VPS Caddy handles HTTPS so backends don't have to |
| **Host-based routing** | Laptop Caddy routes `portainer.caktus.duckdns.org` → container port 9000 |
| **Single entry point** | Only ports 80/443 exposed; all apps behind one gateway |
| **Load balancing** | Not used here, but Caddy supports it if you scale an app to multiple containers |
| **Header injection** | VPS Caddy adds `X-Forwarded-For`, `X-Real-IP` for logging |

---

## 2. Why Caddy Over Nginx or Traefik

### Comparison

| Feature | Caddy | Nginx | Traefik |
|---|---|---|---|
| **Auto HTTPS** | Built-in (Let's Encrypt, zero config) | Requires Certbot + cron | Built-in |
| **Config format** | Caddyfile (human-readable) | nginx.conf (C-like blocks) | YAML/TOML or Docker labels |
| **Config reload** | Graceful, zero-downtime | `nginx -s reload` (usually fine) | Automatic via Docker events |
| **DNS-01 plugins** | Official plugins (DuckDNS, Cloudflare, etc.) | Requires external tools | Requires provider plugins |
| **HTTP/2, HTTP/3** | Default | Configurable | Default |
| **WebSocket** | Automatic | Requires `proxy_pass` + header config | Automatic |
| **Memory usage** | ~15–30 MB | ~5–10 MB | ~30–50 MB |
| **Learning curve** | Very low | Medium | Medium |

### Why Caddy Wins for Caktus

1. **Zero-config TLS**: Caddy gets wildcard certs from Let's Encrypt using the DuckDNS DNS-01 plugin. With Nginx, you'd need to install Certbot, write a hook script for DuckDNS, set up cron renewal, and manage cert files manually.

2. **Readable config**: A Caddy route is 3 lines. Nginx equivalent is 10–15 lines with `server_name`, `location /`, `proxy_pass`, `proxy_set_header` blocks.

3. **WebSocket support**: Caddy handles WebSocket proxying automatically. This matters for Uptime Kuma, which uses WebSockets for its real-time dashboard. With Nginx, you'd need explicit `Upgrade` and `Connection` header configuration.

4. **Graceful reload**: `caddy reload` applies config changes without dropping active connections. This is how `add-app.sh` adds new routes without affecting running apps.

---

## 3. The Dual-Caddy Architecture

Caktus runs two separate Caddy instances with completely different roles:

```
                                INTERNET
                                   │
                          ┌────────▼────────┐
                          │   VPS CADDY     │
                          │                  │
                          │ Listen: :443     │
                          │ TLS: *.caktus.   │
                          │   duckdns.org    │
                          │ Route: ALL →     │
                          │   10.0.0.2:80    │
                          │                  │
                          │ Config: 15 lines │
                          │ Changes: NEVER   │
                          └────────┬─────────┘
                                   │ WireGuard
                          ┌────────▼─────────┐
                          │  LAPTOP CADDY    │
                          │                   │
                          │ Listen: :80       │
                          │ TLS: OFF          │
                          │ Route: by Host    │
                          │   header          │
                          │                   │
                          │ Config: grows     │
                          │   with each app   │
                          └───────────────────┘
```

### Why Two Instances?

| Aspect | If One Caddy (VPS) | Two Caddys (current) |
|---|---|---|
| Adding a new app | SSH into VPS, edit config | Edit laptop file, reload |
| VPS knows about apps | Yes (routing table) | No (blind pipe) |
| VPS is stateful | Yes | No |
| Config location | Split between VPS and laptop | All on laptop |
| VPS replacement | Need to copy routing config | Just install Caddy, paste 15 lines |

The two-Caddy pattern keeps the VPS **completely stateless and app-unaware**.

---

## 4. VPS Caddyfile Explained

```caddyfile
{
    email your@email.com
}
```

The **global options block** (in `{}`):
- `email` — used by Let's Encrypt for certificate expiry notifications and account registration. Let's Encrypt will email you 30 days before a cert expires (shouldn't happen since Caddy auto-renews, but it's a safety net).

```caddyfile
*.caktus.duckdns.org, caktus.duckdns.org {
```

This **site block** matches two patterns:
- `*.caktus.duckdns.org` — any subdomain (portainer, status, hello, etc.)
- `caktus.duckdns.org` — the bare domain (for the landing page)

When both are in the same block, Caddy gets **one wildcard certificate** that covers everything. This is efficient — one certificate, one ACME challenge, one renewal cycle.

```caddyfile
    tls {
        dns duckdns YOUR_DUCKDNS_TOKEN
    }
```

The `tls` block configures certificate issuance:
- `dns duckdns` — use the DuckDNS DNS-01 challenge provider
- `YOUR_DUCKDNS_TOKEN` — your DuckDNS API token (used to create TXT records for the challenge)

This requires a custom-built Caddy binary with the `caddy-dns/duckdns` plugin. Standard Caddy from the package manager doesn't include DNS providers.

```caddyfile
    reverse_proxy 10.0.0.2:80 {
        header_up Host {host}
        header_up X-Forwarded-For {remote}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-Proto {scheme}
    }
```

The reverse proxy sends all traffic to `10.0.0.2:80` (laptop Caddy via WireGuard):
- `header_up Host {host}` — **critical**: preserves the original `Host` header (e.g., `portainer.caktus.duckdns.org`) so laptop Caddy can route correctly. Without this, laptop Caddy wouldn't know which app was requested.
- `header_up X-Forwarded-For {remote}` — tells the backend the client's real IP (not the VPS IP)
- `header_up X-Real-IP {remote}` — same, different header name (some apps read one or the other)
- `header_up X-Forwarded-Proto {scheme}` — tells the backend whether the original request was HTTP or HTTPS

---

## 5. Laptop Caddyfile Explained

```caddyfile
{
    auto_https off
    admin off
}
```

Global options:
- `auto_https off` — disables Caddy's automatic HTTPS redirect and certificate management. The laptop Caddy runs on plain HTTP because TLS is already handled by VPS Caddy. Without this, Caddy would try (and fail) to get certificates.
- `admin off` — disables Caddy's admin API (normally on `localhost:2019`). This reduces attack surface — if an attacker gains local access, they can't use the admin API to reconfigure routing.

```caddyfile
:80 {
```

Listen on port 80, all interfaces. This single block contains all routing rules. Since `auto_https` is off, Caddy won't redirect to HTTPS or try to listen on 443.

### Route Pattern (Repeated for Each App)

```caddyfile
    @landing host caktus.duckdns.org
    handle @landing {
        reverse_proxy caktus-landing:80
    }
```

This is Caddy's **named matcher** + **handle** pattern:

1. `@landing` defines a named matcher: "match requests where the `Host` header is `caktus.duckdns.org`"
2. `handle @landing {}` says: "for requests matching `@landing`, do this"
3. `reverse_proxy caktus-landing:80` forwards to the container named `caktus-landing` on its internal port `80`

Docker DNS resolves `caktus-landing` to the container's IP on `caktus-net` (e.g., `172.20.0.5`). No hardcoded IPs needed.

### The Default Handler

```caddyfile
    handle {
        respond "🌵 Caktus — Unknown subdomain. Check your Caddyfile." 404
    }
```

If no named matcher matches the request's Host header, this catch-all returns a 404 with a helpful message. This handles cases like `unknown.caktus.duckdns.org` — the DNS resolves (wildcard), the TLS cert works (wildcard), but there's no app configured for this subdomain.

---

## 6. Host-Based Routing (Named Matchers)

### How It Works Under the Hood

When the laptop Caddy receives an HTTP request, the first thing it examines is the `Host` header:

```http
GET / HTTP/1.1
Host: portainer.caktus.duckdns.org
Accept: text/html
X-Forwarded-For: 203.x.x.x
```

Caddy evaluates named matchers in order of specificity:

```
Request Host: portainer.caktus.duckdns.org

  Check @landing  (host == caktus.duckdns.org)        → no match
  Check @hello    (host == hello.caktus.duckdns.org)   → no match
  Check @portainer(host == portainer.caktus.duckdns.org)→ ✅ MATCH!
  
  → Execute: reverse_proxy caktus-portainer:9000
```

### Why Named Matchers, Not `server_name`

Nginx uses a `server_name` directive inside separate `server` blocks. Caddy's approach is different — all routes are inside one `:80` block, differentiated by named matchers. This is arguably cleaner because:
- All routing is in one place (one block, not N blocks)
- No risk of conflicting server blocks
- Easy to see the full routing table at a glance

### How Many Apps Can One Block Handle?

Effectively unlimited. Each named matcher is a constant-time string comparison on the Host header. Adding 100 apps means 100 matchers, which is negligible overhead. The bottleneck is Docker container memory, not Caddy routing.

---

## 7. How Caddy Handles WebSocket, HTTP/2, and gRPC

### WebSocket

Uptime Kuma uses WebSocket for its real-time monitoring dashboard. When a client sends a WebSocket upgrade request:

```http
GET /ws HTTP/1.1
Host: status.caktus.duckdns.org
Upgrade: websocket
Connection: Upgrade
```

Caddy detects the `Upgrade: websocket` header and automatically:
1. Forwards the upgrade to the backend
2. Switches from HTTP to a persistent WebSocket connection
3. Proxies frames bidirectionally

**No configuration needed.** Nginx requires explicit header forwarding:
```nginx
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

Caddy does this transparently.

### HTTP/2

VPS Caddy serves clients over HTTP/2 by default when TLS is active. HTTP/2 provides:
- **Multiplexing**: multiple requests over one TCP connection (no head-of-line blocking)
- **Header compression**: HPACK reduces header overhead
- **Server push**: Caddy can push resources proactively (not used in Caktus)

Between VPS Caddy and laptop Caddy, the connection is HTTP/1.1 over WireGuard. This is fine because the internal hop doesn't benefit from multiplexing.

---

## 8. The Wildcard TLS Pattern

### Why Wildcard?

Without a wildcard cert, you'd need a separate TLS certificate for each subdomain:
- `caktus.duckdns.org` → cert 1
- `portainer.caktus.duckdns.org` → cert 2
- `status.caktus.duckdns.org` → cert 3
- Each new app → new cert

With a wildcard cert for `*.caktus.duckdns.org`:
- One cert covers all current and future subdomains
- Adding a new app doesn't require any TLS changes
- One renewal cycle, one ACME challenge

### DNS-01 Is Required

Wildcard certs can *only* be obtained via DNS-01 challenges (not HTTP-01). This is because:
- HTTP-01 proves you control a specific server at that hostname
- But `*.caktus.duckdns.org` isn't a single hostname — it's infinite hostnames
- DNS-01 proves you control the *domain itself* (by creating a TXT record)

### The Challenge Flow

```
1. Caddy: "I want a cert for *.caktus.duckdns.org"
   → Connects to Let's Encrypt ACME server

2. Let's Encrypt: "Create this TXT record:
   _acme-challenge.caktus.duckdns.org = AbCdEf123456"

3. Caddy calls DuckDNS API:
   https://www.duckdns.org/update?domains=caktus&token=TOKEN&txt=AbCdEf123456

4. Let's Encrypt queries DNS for:
   TXT _acme-challenge.caktus.duckdns.org

5. DNS returns: AbCdEf123456 → ✅ Match!

6. Let's Encrypt issues wildcard cert (valid 90 days)

7. Caddy stores cert and begins serving TLS

8. Caddy auto-renews 30 days before expiry
```

### Why This Needs xcaddy

The standard Caddy binary doesn't include DNS provider plugins. You need to build a custom Caddy with the DuckDNS plugin:

```bash
# Install xcaddy (Caddy build tool)
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

# Build Caddy with DuckDNS plugin
xcaddy build --with github.com/caddy-dns/duckdns

# The output is a custom caddy binary with DNS-01 support
```

This custom binary is installed on the VPS only. The laptop uses standard `caddy:alpine` (from Docker Hub) because it doesn't handle TLS.

---

## 9. Header Forwarding & Preserving Client IPs

### The Problem

When VPS Caddy forwards a request to laptop Caddy, the laptop sees the connection as coming from `10.0.0.1` (the VPS WireGuard IP) — not the real client. Without header forwarding, your app logs would show every request as coming from the same IP.

### The Solution

VPS Caddy adds forwarding headers:

```
Original request from 203.0.113.42:

VPS Caddy → Laptop Caddy:
  Host: portainer.caktus.duckdns.org         ← preserved
  X-Forwarded-For: 203.0.113.42             ← real client IP
  X-Real-IP: 203.0.113.42                   ← same, alt header
  X-Forwarded-Proto: https                   ← original was HTTPS
```

Applications that respect these headers (most do) will:
- Log the real client IP
- Generate correct URLs with `https://` prefix
- Apply geo-based logic correctly

### Trust Configuration

In production, you'd configure backends to only trust `X-Forwarded-For` from known proxies (to prevent spoofing). In Caktus, since all traffic goes through the private Docker network and WireGuard tunnel, spoofing isn't a concern — the only way to reach the laptop's Caddy is through the WireGuard tunnel.

---

## 10. Zero-Downtime Config Reloads

When you add a new app, you edit the Caddyfile and reload:

```bash
docker exec caktus-caddy caddy reload --config /etc/caddy/Caddyfile
```

What happens internally:

```
1. Caddy reads the new config file
2. Caddy validates the config (syntax + logic)
3. If valid: Caddy atomically swaps the routing table
4. Active connections continue on old routes until they close naturally
5. New connections use new routes immediately

Result: Zero dropped connections, zero downtime
```

If the config is invalid, Caddy rejects it and continues with the old config. This is fail-safe — a typo doesn't bring down your server.

### Why Not `docker compose restart caddy`?

Restarting the container stops the Caddy process entirely, drops all connections, pulls a new container, and starts fresh. During the ~2 seconds of restart, all requests get `connection refused`. The reload command avoids this entirely.

---

## 11. Adding a New App Route

The `add-app.sh` script automates this, but here's what happens:

### Step 1: Add to Caddyfile

Insert before the default `handle {}` block:

```caddyfile
    @myapp host myapp.caktus.duckdns.org
    handle @myapp {
        reverse_proxy caktus-myapp:3000
    }
```

That's it. Three lines.

### Step 2: Reload

```bash
docker exec caktus-caddy caddy reload --config /etc/caddy/Caddyfile
```

### Step 3: Verify

```bash
# Should return the app's response (or 502 if container isn't running yet)
curl -H "Host: myapp.caktus.duckdns.org" http://localhost/
```

### Why No TLS Changes?

The wildcard cert on the VPS already covers `*.caktus.duckdns.org`. A new subdomain `myapp.caktus.duckdns.org` is automatically covered. No cert re-issuance, no DNS changes (wildcard DNS resolves all subdomains to the same IP).

---

## 12. Caddy in Docker vs Host Install

### Laptop: Docker (caddy:alpine)

```yaml
caddy:
  image: caddy:alpine
  container_name: caktus-caddy
  ports:
    - '80:80'
    - '443:443'
  volumes:
    - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
    - caddy_data:/data
    - caddy_config:/config
  networks:
    - caktus-net
  restart: unless-stopped
```

Running in Docker provides:
- Automatic DNS resolution of container names (via `caktus-net`)
- Same lifecycle management as all other services (`docker compose up -d`)
- Easy rollback (`docker compose pull caddy` for updates)
- Mount Caddyfile read-only (`:ro`) — container can't modify its own config

### VPS: Host Install (with xcaddy)

The VPS Caddy runs directly on the host (not in Docker) because:
- It needs the custom `caddy-dns/duckdns` plugin (xcaddy build)
- It doesn't need Docker DNS (it only proxies to one IP: `10.0.0.2`)
- Fewer moving parts — the VPS should be as simple as possible
- Managed by systemd: `sudo systemctl restart caddy`

### Volume Mounts

| Volume | Purpose | Persistent? |
|---|---|---|
| `./caddy/Caddyfile` | Routing config (bind mount, read-only) | Yes (on host filesystem) |
| `caddy_data` | TLS certs, OCSP stapled responses | Yes (Docker volume) — but not critical on laptop since VPS handles TLS |
| `caddy_config` | Admin state, auto-generated config | Yes (Docker volume) |

---

## 13. Troubleshooting Caddy

### 502 Bad Gateway

The backend container is down or not reachable.

```bash
# 1. Check if the container exists and is running
docker compose ps

# 2. Check container logs
docker compose logs -f myapp

# 3. Restart the container
docker compose up -d myapp

# 4. If still 502, verify the port matches
# Caddyfile says: reverse_proxy caktus-myapp:3000
# Container must be listening on port 3000 internally
docker exec caktus-myapp netstat -tlnp   # or ss -tlnp
```

### 404 on a Valid Subdomain

Caddy doesn't have a route for this subdomain.

```bash
# Check if the route exists in Caddyfile
grep "myapp" ~/caktus/caddy/Caddyfile

# Verify exact spelling
# The matcher must exactly match: myapp.caktus.duckdns.org
```

### Connection Refused

Caddy itself is down.

```bash
docker compose ps caddy    # is it running?
docker compose logs caddy  # why did it crash?
docker compose up -d caddy # restart
```

### Invalid Caddyfile After Editing

```bash
# Validate before reloading
docker exec caktus-caddy caddy validate --config /etc/caddy/Caddyfile

# If valid:
docker exec caktus-caddy caddy reload --config /etc/caddy/Caddyfile

# If invalid: fix the Caddyfile, then validate again
```

### Testing a Route Locally

```bash
# From the laptop — bypass DNS and VPS, talk directly to laptop Caddy
curl -H "Host: portainer.caktus.duckdns.org" http://localhost/

# Expected: Portainer HTML response
# If 502: Portainer container is down
# If 404: Host matcher doesn't match this subdomain
```

---

## Key Takeaways

1. **Caddy is chosen for automatic TLS** — the killer feature is zero-config wildcard certs via DNS-01
2. **Two Caddy instances** cleanly separate TLS (VPS) from routing (laptop)
3. **Named matchers** (`@name host subdomain.domain`) route by Host header — 3 lines per app
4. **Zero-downtime reload** — `caddy reload` is atomic, never drops connections
5. **WebSocket, HTTP/2** are automatic — no extra config needed
6. **Wildcard cert** means new apps need zero TLS changes
7. **VPS Caddyfile is write-once** — all app management happens on the laptop
8. **Docker DNS** resolves container names — no manual IPs in Caddyfile

---

*Part of Project Caktus documentation suite*
