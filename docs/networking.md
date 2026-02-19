# Computer Networking Deep Dive
## How Caktus Works at Every Layer

> This document explains every networking concept Caktus relies on.
> Read this to truly understand the project — not just what it does, but why.

---

## Table of Contents

1. [The Problem: Why Laptops Can't Be Servers](#1-the-problem)
2. [IP Addressing: Public vs Private](#2-ip-addressing)
3. [NAT: Network Address Translation](#3-nat)
4. [CGNAT: Carrier-Grade NAT](#4-cgnat)
5. [The Solution: VPS Relay Architecture](#5-the-solution)
6. [DNS: How Names Become IPs](#6-dns)
7. [TCP/IP: The Protocol Stack](#7-tcpip)
8. [UDP: Why WireGuard Uses It](#8-udp)
9. [WireGuard: Modern VPN Tunneling](#9-wireguard)
10. [TLS/HTTPS: Encryption in Transit](#10-tlshttps)
11. [Reverse Proxy: Routing by Name](#11-reverse-proxy)
12. [Docker Networking: Containers on a Bridge](#12-docker-networking)
13. [The Full Packet Journey](#13-the-full-packet-journey)

---

## 1. The Problem

Imagine you want to host a web app on your laptop at home. You run `python -m http.server 8080`. It's accessible at `localhost:8080` on your machine. But if a friend tries to reach it from the internet — it fails. Why?

Your laptop has a **private IP address** (like `192.168.1.100`). Private IPs are not routable on the public internet. Only your home router has a public IP — and even then, your router has no idea that your laptop is waiting on port 8080.

This is the **NAT problem**, and it gets worse: most ISPs don't even give you a real public IP anymore. They put you behind a second layer called **CGNAT**.

---

## 2. IP Addressing

### IPv4 Address Space

IPv4 addresses are 32-bit numbers, written as four octets: `192.168.1.100`. There are ~4.3 billion possible addresses. That sounds like a lot, but we've run out.

### Public vs Private IP Ranges

The Internet Assigned Numbers Authority (IANA) reserved three ranges for **private use** (RFC 1918):

| Range | CIDR | Hosts | Typical use |
|---|---|---|---|
| `10.0.0.0` | `10.0.0.0/8` | ~16.7M | Corporate networks, WireGuard |
| `172.16.0.0` | `172.16.0.0/12` | ~1M | Docker default bridge |
| `192.168.0.0` | `192.168.0.0/16` | ~65K | Home routers |

Private IPs are **not routable on the internet**. Routers on the public internet will drop packets destined for these ranges.

**In Caktus:**
- Your laptop: `192.168.1.100` (home LAN — private)
- Docker network: `172.20.0.0/16` (custom bridge — private)
- WireGuard VPN: `10.0.0.0/24` (tunnel — private but routed through WireGuard)
- VPS: `<public IP>` (actually reachable from the internet)

### CIDR Notation

`172.20.0.0/16` means: the first 16 bits are the network address, the remaining 16 bits are for hosts. With 16 bits for hosts, you get 2^16 = 65,536 possible addresses.

`10.0.0.1/32` means a single specific host (all 32 bits are fixed) — used in WireGuard `AllowedIPs` to say "only route traffic for this exact IP through the tunnel."

---

## 3. NAT

**Network Address Translation (NAT)** is how your home router lets multiple devices share one public IP.

### How it Works

```
Your laptop: 192.168.1.100:54321  ──▶  Google: 8.8.8.8:443
                                    ↕
                        Home Router NAT Table:
                  [192.168.1.100:54321] ↔ [Router-Public-IP:11111]
                                    ↕
Your laptop receives response     ◀──  Google: 8.8.8.8:443
```

1. Your laptop sends a packet to 8.8.8.8. Source: `192.168.1.100:54321`.
2. Router replaces source with its own public IP + a new port: `RouterIP:11111`.
3. Router remembers this mapping in the **NAT table**.
4. Google's response arrives at `RouterIP:11111`.
5. Router looks up its NAT table, rewrites destination to `192.168.1.100:54321`, forwards to laptop.

**The critical insight:** NAT tables are built from *outbound* connections. Your router has no entry for *inbound* connections that nobody initiated. If someone tries to connect to `RouterIP:8080` directly — the router drops it, because there's no NAT table entry for it.

### Port Forwarding

You could tell your router: "if someone connects on port 80, forward to 192.168.1.100:80." This is **port forwarding**. But it requires router admin access — which most ISPs don't give you, and which doesn't work at all with CGNAT.

---

## 4. CGNAT

**Carrier-Grade NAT** is NAT done by your ISP — above your home router. It's NAT on NAT.

```
Your Laptop
  192.168.1.100
      │
      ▼
Your Home Router (NAT layer 1)
  Your "public" IP from ISP: 100.64.x.x  ← This is ALSO private!
      │
      ▼
ISP's CGNAT Router (NAT layer 2)
  Actual public IP: 203.x.x.x
      │
      ▼
   Internet
```

CGNAT uses the `100.64.0.0/10` range (RFC 6598) — technically not RFC 1918, but also not routable on the public internet.

**Why ISPs do this:** IPv4 exhaustion. There aren't enough public IPv4 addresses to give one to every home. CGNAT lets thousands of homes share one public IP.

**Why this breaks hosting:**
- You can't port-forward through CGNAT — you don't control the ISP's NAT.
- Even if you port-forward on your own router, the ISP NAT layer blocks inbound connections.
- There is simply no way to receive a direct inbound TCP connection from the internet.

**Caktus's solution:** Instead of trying to receive inbound connections, we make an *outbound* connection from the laptop to the VPS via WireGuard. Outbound connections work through any NAT. The VPS then relays incoming traffic through this already-established tunnel.

---

## 5. The Solution

### Why Not Other Solutions?

| Solution | Problem |
|---|---|
| **Cloudflare Tunnel** | Traffic goes through Cloudflare servers — data is theirs |
| **Tailscale** | Closed-source control plane — not truly self-hosted |
| **ngrok** | Rate-limited free tier, URLs change, not production-grade |
| **DDNS + Port Forward** | Doesn't work with CGNAT |
| **IPv6** | ISP may not support it; not universally accessible |

### The VPS Relay Pattern

```
  PROBLEM: Inbound TCP connections can't reach your laptop
  SOLUTION: Tunnel outbound UDP from laptop, relay inbound TCP on VPS

  ┌─────────────────────────────────────────────────────────┐
  │  INSIGHT: WireGuard UDP works outbound through any NAT. │
  │  Once the tunnel is up, the VPS can push traffic        │
  │  back through it because the NAT table has the entry.   │
  └─────────────────────────────────────────────────────────┘

  Laptop ──(UDP outbound)──▶ VPS WireGuard server
                                  │ (NAT table entry exists now)
  Internet User ──(TCP :443)──▶ VPS
                                  │
                                  └──(through tunnel)──▶ Laptop
```

The VPS's role is **pure relay** — it does not store data, process requests, or run application logic. If the VPS disappears, you spin up a new one, re-run 3 commands, and everything works again in minutes.

---

## 6. DNS

**Domain Name System (DNS)** is the internet's phone book. It maps human-readable names to IP addresses.

### How DNS Resolution Works

```
Browser: "What is the IP of caktus.duckdns.org?"

  1. Check local DNS cache → miss
  2. Ask OS resolver (e.g., 1.1.1.1 or 8.8.8.8)
  3. Resolver asks root nameserver: "Who handles .org?"
     → Root: "Ask .org TLD nameserver at 199.19.54.1"
  4. Resolver asks .org TLD: "Who handles duckdns.org?"
     → TLD: "Ask DuckDNS nameserver at ns1.duckdns.org"
  5. Resolver asks DuckDNS: "What is caktus.duckdns.org?"
     → DuckDNS: "It's <VPS_IP>" (A record)
  6. Browser gets <VPS_IP>, starts TCP connection
```

### DNS Record Types

| Type | Purpose | Example |
|---|---|---|
| **A** | Maps name to IPv4 | `caktus.duckdns.org → 203.x.x.x` |
| **AAAA** | Maps name to IPv6 | (not used here) |
| **CNAME** | Alias to another name | `www → caktus` |
| **TXT** | Text data | Used for DNS-01 ACME challenge |
| **NS** | Nameserver for domain | `duckdns.org → ns1.duckdns.org` |

### TTL (Time to Live)

Every DNS record has a TTL in seconds. Caches store the record for that long before asking again. DuckDNS uses TTL=60. This means if your VPS IP changes, DNS updates propagate within 60 seconds.

### DNS-01 ACME Challenge (Wildcard Certs)

To prove you own `*.caktus.duckdns.org`, Let's Encrypt uses a DNS-01 challenge:

```
1. Let's Encrypt: "Prove you control this domain by adding
   a TXT record: _acme-challenge.caktus.duckdns.org = <token>"

2. Caddy uses DuckDNS API (your TOKEN) to create that TXT record.

3. Let's Encrypt's servers look up that TXT record via DNS.

4. If it matches, you're verified → cert issued.

5. Caddy deletes the TXT record.
```

This works for wildcards because DNS-01 proves *domain ownership* (not just server control). HTTP-01 challenge can't prove you own `*.caktus.duckdns.org` because there's no single server at that address.

### Docker Internal DNS

Docker provides DNS resolution inside `caktus-net`. When Caddy does `reverse_proxy caktus-portainer:9000`, Docker's internal DNS resolves `caktus-portainer` to that container's IP (`172.20.x.x`). No manual IP management needed. This is why containers are named `caktus-*`.

---

## 7. TCP/IP

### The Internet Protocol Stack

```
┌─────────────────────────────────────────────────────┐
│  Application Layer  (HTTP, HTTPS, WireGuard)        │
│  What the app sends/receives                        │
├─────────────────────────────────────────────────────┤
│  Transport Layer  (TCP, UDP)                        │
│  Reliable delivery (TCP) or fast (UDP)              │
├─────────────────────────────────────────────────────┤
│  Internet Layer  (IP)                               │
│  Routing packets from source to destination         │
├─────────────────────────────────────────────────────┤
│  Network Layer  (Ethernet, WiFi)                    │
│  Physical transmission on your LAN                  │
└─────────────────────────────────────────────────────┘
```

### TCP: Reliable, Ordered Delivery

**TCP (Transmission Control Protocol)** provides:
- **Reliability**: Lost packets are retransmitted
- **Order**: Packets arrive in the order they were sent
- **Flow control**: Sender doesn't overwhelm receiver

TCP uses a **3-way handshake** before any data flows:
```
Client → Server: SYN           (I want to connect)
Client ← Server: SYN-ACK       (OK, I'm listening)
Client → Server: ACK           (Great, let's go)
         [Connection established]
```

HTTPS (and therefore your web apps) runs over TCP. The browser and VPS Caddy do this handshake, then negotiate TLS on top.

### IP: Routing Between Networks

**IP (Internet Protocol)** is responsible for getting packets from source to destination, potentially through many intermediate routers ("hops"). Each router reads the destination IP and forwards the packet toward it based on routing tables.

IP is **connectionless** — each packet is independent. A 1MB file is broken into ~700 IP packets, each potentially taking a different route.

### Ports: Which App Gets the Packet?

A single server runs many services. Ports distinguish them:
- Port 80: HTTP
- Port 443: HTTPS
- Port 22: SSH
- Port 51820/UDP: WireGuard
- Port 9000: Portainer

When a packet arrives, the OS looks at the destination port and hands the data to the right process.

---

## 8. UDP

**UDP (User Datagram Protocol)** is TCP's simpler sibling:
- **No connection establishment** — just send packets
- **No reliability** — packets can be lost, no retransmission
- **No ordering** — packets can arrive out of order
- **Faster** — less overhead, lower latency

WireGuard uses UDP for its tunnel because:
1. **Speed**: No handshake overhead — just encrypt and send
2. **NAT traversal**: UDP is easier to punch through NAT than TCP
3. **Flexibility**: WireGuard handles its own reliability at the cryptographic layer
4. **Lower latency**: Critical for VPN that wraps other connections

The trade-off (lost packets) is acceptable because:
- WireGuard carries TCP traffic inside the tunnel
- If a WireGuard UDP packet is lost, the inner TCP protocol retransmits
- Modern networks rarely drop packets

---

## 9. WireGuard

### What WireGuard Does

WireGuard creates a **virtual network interface** (`wg0`) that looks like a normal network card to the OS. Any IP packet sent to a WireGuard address is encrypted and sent as a UDP datagram to the real physical address of the peer.

```
App wants to reach 10.0.0.1 (VPS VPN IP):
  1. OS routing table: "10.0.0.1 → send via wg0"
  2. WireGuard: encrypts packet with peer's public key
  3. WireGuard: sends encrypted UDP to <VPS_PUBLIC_IP>:51820
  4. VPS WireGuard receives UDP, decrypts with its private key
  5. Delivers decrypted packet to 10.0.0.1 on wg0 interface
  6. As if the machines are directly connected
```

### Cryptography

WireGuard uses **state-of-the-art cryptography** with no negotiation — the algorithms are fixed (no cipher suite negotiation that could be downgraded):

| Operation | Algorithm | Why |
|---|---|---|
| **Key exchange** | Curve25519 (Elliptic-curve Diffie-Hellman) | Forward secrecy, small keys |
| **Data encryption** | ChaCha20-Poly1305 | Fast, secure, authenticated |
| **Handshake** | Noise Protocol Framework | Formal security proof |
| **Key derivation** | BLAKE2s | Fast hashing |

**Asymmetric keys**: Each peer has a public key and a private key. Public keys are shared freely. Private keys never leave the machine they're generated on.

**Forward secrecy**: Even if a private key is compromised later, past sessions cannot be decrypted. WireGuard negotiates new session keys every few minutes.

### AllowedIPs = Routing Table

`AllowedIPs` in WireGuard does two things:
1. **Outbound**: Only route these destination IPs through this peer's tunnel
2. **Inbound**: Only accept packets from this peer if they claim to be from these IPs

On the laptop:
```
AllowedIPs = 10.0.0.1/32
```
This means: "only route traffic to 10.0.0.1 through the VPS tunnel." All other internet traffic goes through the normal network. This is **split tunneling** — we don't route all traffic through the VPS (that would be slow and defeat the purpose).

### PersistentKeepalive

NAT tables expire. If no traffic flows through the tunnel for ~30 seconds, your ISP router forgets the mapping and the tunnel silently dies.

`PersistentKeepalive = 25` sends a keepalive UDP packet every 25 seconds — just enough to keep the NAT table entry alive. Without this, a laptop sitting idle for 30 seconds would need to re-establish the tunnel before the next request could flow. The keepalive is tiny (only 32 bytes) and has negligible overhead.

---

## 10. TLS/HTTPS

### Why HTTPS?

HTTP sends data in plaintext — anyone on the network path can read it. A coffee shop WiFi operator, your ISP, any router between you and the server. HTTPS encrypts everything with **TLS (Transport Layer Security)**.

### TLS Handshake (Simplified)

```
Browser                              Server
  │                                    │
  │── ClientHello ──────────────────▶  │  "I support TLS 1.3, here are my cipher suites"
  │                                    │
  │◀─ ServerHello ─────────────────── │  "Let's use TLS 1.3 + ChaCha20"
  │◀─ Certificate ─────────────────── │  "Here's my cert (signed by Let's Encrypt)"
  │◀─ ServerKeyShare ──────────────── │  "Here's my DH public key"
  │                                    │
  │── ClientKeyShare ───────────────▶ │  "Here's my DH public key"
  │── Finished ──────────────────────▶ │  (encrypted with derived session key)
  │                                    │
  │◀─ Finished ─────────────────────── │  (encrypted — handshake confirmed)
  │                                    │
  [All further data: encrypted with session key]
```

**Diffie-Hellman key exchange** lets both sides derive the same secret session key without ever transmitting it — even an eavesdropper who sees all the messages can't derive the key. This provides **perfect forward secrecy**.

### Certificate Chains

When your browser sees `*.caktus.duckdns.org`, it checks if it trusts the certificate. Certificates form a **chain of trust**:

```
Root CA (pre-installed in your browser/OS)
  └── Let's Encrypt Intermediate CA
        └── *.caktus.duckdns.org  ← Caddy presents this
```

Let's Encrypt is a free, automated Certificate Authority. Browsers trust Let's Encrypt because it's cross-signed by root CAs that browsers already trust.

### ACME Protocol

**ACME (Automatic Certificate Management Environment)** is the protocol Caddy uses to get certificates automatically:

```
1. Caddy tells Let's Encrypt: "I want a cert for *.caktus.duckdns.org"
2. Let's Encrypt: "Prove you control it — DNS-01 challenge"
3. Caddy calls DuckDNS API: adds TXT record _acme-challenge.caktus.duckdns.org
4. Let's Encrypt verifies TXT record via DNS
5. Let's Encrypt issues cert, valid for 90 days
6. Caddy auto-renews 30 days before expiry
7. Caddy deletes the TXT record
```

This is entirely automated. You never touch a certificate manually.

### Why We Need DNS-01 for Wildcards

The other challenge type (HTTP-01) works by placing a file at `http://caktus.duckdns.org/.well-known/acme-challenge/<token>`. But for `*.caktus.duckdns.org` (wildcard), there's no single server at that address — any subdomain could be pointed anywhere. DNS-01 is the only way to prove you own the entire wildcard domain.

---

## 11. Reverse Proxy

### What Is a Reverse Proxy?

A **reverse proxy** sits between the internet and your backend servers. Clients connect to it — they never connect directly to backend apps.

```
Without reverse proxy:
  Browser → app1:3000  (requires exposing raw port)
  Browser → app2:8080  (different port for each app — ugly URLs)

With reverse proxy:
  Browser → caddy:443 (one endpoint, HTTPS, clean URLs)
    → routes to app1:3000  (based on app1.domain.com)
    → routes to app2:8080  (based on app2.domain.com)
```

Benefits:
- **Single entry point**: Only one port exposed (443)
- **TLS termination**: Proxy handles HTTPS; backends use plain HTTP
- **Host-based routing**: Multiple apps on one IP via subdomains
- **Security**: Backends are not directly exposed to internet

### Host-Based Routing

When a browser sends `GET /path HTTP/1.1`, it includes a `Host: header`:
```http
GET / HTTP/1.1
Host: portainer.caktus.duckdns.org
Accept: text/html
```

Caddy reads the `Host` header and decides which backend to forward to:
```caddyfile
@portainer host portainer.caktus.duckdns.org
handle @portainer {
    reverse_proxy caktus-portainer:9000
}
```

This is how one Caddy instance serving port 80 can route to dozens of different apps — all based on which subdomain was requested.

### The VPS–Laptop Caddy Split

Caktus uses **two Caddy instances** for a clean separation of concerns:

| | VPS Caddy | Laptop Caddy |
|---|---|---|
| **Purpose** | TLS gateway | App router |
| **Listens on** | `:80`, `:443` (public) | `:80` (via WireGuard only) |
| **TLS** | Yes — wildcard cert | No — `auto_https off` |
| **Routes** | All `*.caktus.duckdns.org` → `10.0.0.2:80` | Per-app host routing |
| **Knows about apps** | No — blind relay | Yes — routes to each container |

---

## 12. Docker Networking

### The Bridge Network

`caktus-net` is a **user-defined bridge network** — a virtual switch that only exists inside the host machine. When containers join it, Docker assigns them IPs in the `172.20.0.0/16` subnet and gives each an internal hostname matching its container name.

```
caktus-net (bridge, 172.20.0.0/16)
  │
  ├── caktus-caddy      172.20.0.2
  ├── caktus-portainer  172.20.0.3
  ├── caktus-uptime     172.20.0.4
  ├── caktus-landing    172.20.0.5
  └── caktus-hello      172.20.0.6
```

**Container DNS**: Docker runs an internal DNS resolver for each bridge network. When Caddy does `reverse_proxy caktus-portainer:9000`, Docker DNS resolves `caktus-portainer` → `172.20.0.3`. No manual IP management, no `/etc/hosts` entries.

### Why User-Defined Bridges vs Default Bridge

Docker's default bridge (`docker0`) doesn't provide DNS resolution between containers — you'd have to use IP addresses manually. User-defined bridges (`caktus-net`) give you:
- Container name DNS resolution
- Network isolation (containers on `caktus-net` can't talk to containers on other networks)
- Explicit membership (you know exactly which containers can talk to each other)

### Port Isolation

Only `caktus-caddy` binds host ports:
```yaml
ports:
  - '80:80'
  - '443:443'
```

Every other container has **no port bindings** — they're invisible to anything outside `caktus-net`. Portainer on `9000`, your apps on `3000`, `8080` etc. — none of these are reachable from outside Docker unless Caddy explicitly routes to them. This is the **defense-in-depth** principle: even if an attacker reaches your laptop, they can't access app ports directly.

---

## 13. The Full Packet Journey

Now putting it all together. A request to `https://portainer.caktus.duckdns.org`:

```
Step 1: DNS
  Browser asks: portainer.caktus.duckdns.org
  DuckDNS answers: <VPS_PUBLIC_IP>
  (DuckDNS TTL: 60 seconds — updates within 1 minute if IP changes)

Step 2: TCP Handshake → VPS:443
  3-way SYN/SYN-ACK/ACK between browser and VPS Caddy

Step 3: TLS Handshake
  Browser + VPS Caddy negotiate TLS 1.3
  VPS Caddy presents *.caktus.duckdns.org wildcard cert
  Both sides derive session key via ECDH (Curve25519)
  All further communication: encrypted

Step 4: HTTP Request (inside TLS)
  GET / HTTP/1.1
  Host: portainer.caktus.duckdns.org
  [encrypted by TLS]

Step 5: VPS Caddy Decrypts + Forwards
  VPS Caddy decrypts HTTP
  Matches *.caktus.duckdns.org → forward to 10.0.0.2:80
  Sets headers: Host, X-Forwarded-For, X-Real-IP
  Sends plain HTTP to 10.0.0.2:80

Step 6: WireGuard Encrypts
  Routing table on VPS: 10.0.0.2 → wg0 interface
  WireGuard encrypts with laptop's public key (ChaCha20-Poly1305)
  Sends encrypted UDP to <LAPTOP_WG_ENDPOINT>:51820
  NAT tables: VPS NAT records this outbound mapping (for response routing)

Step 7: Internet Transit
  Encrypted UDP packet traverses internet
  Goes through: VPS → ISP → CGNAT → home router → laptop
  WireGuard keepalive ensures CGNAT table entry is alive

Step 8: Laptop WireGuard Decrypts
  UDP arrives at port 51820
  WireGuard decrypts with laptop's private key
  Verifies authenticity with Poly1305 MAC
  Delivers decrypted packet to wg0 interface (10.0.0.2)

Step 9: Laptop Caddy Reads Host
  Receives HTTP on :80
  Host: portainer.caktus.duckdns.org
  Matches @portainer matcher
  Forwards to caktus-portainer:9000

Step 10: Docker DNS Resolution
  Caddy asks caktus-net DNS: caktus-portainer
  Docker DNS: caktus-portainer → 172.20.0.3
  TCP connection to 172.20.0.3:9000

Step 11: Portainer Responds
  Portainer processes request, sends HTML response

Step 12: Response Traverses Back
  172.20.0.3:9000 → Laptop Caddy → wg0 → WireGuard encrypt →
  UDP to VPS → VPS WireGuard decrypt → VPS Caddy → TLS encrypt →
  TCP to browser → TLS decrypt → browser renders page
```

Total time: typically **30–80ms** for a server in the same continent.

---

## Key Takeaways

1. **CGNAT is why you need a relay** — not your router's fault, it's structural
2. **WireGuard solves NAT traversal** via outbound UDP + keepalive
3. **DNS-01 is the only way to get wildcard TLS certs** without owning the DNS
4. **Docker bridge networks provide internal DNS** — container names as hostnames
5. **Two-layer Caddy** separates TLS concern (VPS) from routing concern (laptop)
6. **The VPS is a pipe, not a server** — this distinction is the whole architecture

---

*Part of Project Caktus documentation suite*
