# Docker & Container Networking Deep Dive
## How Caktus Runs and Isolates Every Application

> Docker is the application runtime layer of Caktus. This document explains
> containers, the bridge network, Docker DNS, volumes, and Compose patterns.

---

## Table of Contents

1. [What Docker Actually Does](#1-what-docker-actually-does)
2. [Containers vs Virtual Machines](#2-containers-vs-virtual-machines)
3. [Linux Kernel Primitives Under Docker](#3-linux-kernel-primitives-under-docker)
4. [The caktus-net Bridge Network](#4-the-caktus-net-bridge-network)
5. [Docker DNS: Container Name Resolution](#5-docker-dns-container-name-resolution)
6. [Port Binding & Isolation](#6-port-binding--isolation)
7. [Docker Compose: Multi-Container Orchestration](#7-docker-compose-multi-container-orchestration)
8. [Volumes & Data Persistence](#8-volumes--data-persistence)
9. [Images & Layers](#9-images--layers)
10. [The Container Lifecycle](#10-the-container-lifecycle)
11. [Health Checks](#11-health-checks)
12. [The Caktus Docker Patterns](#12-the-caktus-docker-patterns)
13. [docker-compose.yml Walkthrough](#13-docker-composeyml-walkthrough)
14. [Troubleshooting Docker](#14-troubleshooting-docker)

---

## 1. What Docker Actually Does

Docker packages an application and all its dependencies (runtime, libraries, config) into a single **image**. When you run an image, Docker creates a **container** — an isolated environment that shares the host's kernel but has its own filesystem, network, and process space.

```
Without Docker:
  Your laptop has: Python 3.8, Node 16, Go 1.19
  App A needs: Python 3.11 → conflict!
  App B needs: Node 18 → conflict!
  App C needs: Go 1.21 → conflict!

With Docker:
  App A container: has Python 3.11 built in
  App B container: has Node 18 built in
  App C container: has Go 1.21 built in
  Each container has its own /usr/bin, /lib, etc.
  No conflicts. Ever.
```

### Key Concepts

| Concept | What It Is | Analogy |
|---|---|---|
| **Image** | Read-only template with app + dependencies | A recipe |
| **Container** | Running instance of an image | A dish made from the recipe |
| **Volume** | Persistent storage that survives container deletion | A pantry shelf |
| **Network** | Virtual network connecting containers | A private phone line |
| **Compose** | Tool for defining multi-container apps | An orchestra conductor |

---

## 2. Containers vs Virtual Machines

```
Virtual Machine:                      Container:
┌──────────────────┐                  ┌──────────────────┐
│ App               │                  │ App               │
│ Libraries         │                  │ Libraries         │
│ Guest OS kernel   │ ← Full OS copy  │ (no guest kernel) │
│ Hypervisor (KVM)  │                  │ Docker Engine     │
│ Host OS kernel    │                  │ Host OS kernel    │ ← Shared!
│ Hardware          │                  │ Hardware          │
└──────────────────┘                  └──────────────────┘

VM overhead: ~1 GB RAM per VM          Container: ~10-50 MB per container
VM boot time: ~30-60 seconds           Container: ~1-2 seconds
```

### Why Containers Win for Caktus

An old laptop with 4–8 GB RAM couldn't run 5 virtual machines. But it can easily run 10+ containers because:
- Containers share the host kernel (no duplicate OS overhead)
- Each container only includes the application layer
- Startup is near-instant (no OS boot)
- Memory is shared through copy-on-write filesystems

---

## 3. Linux Kernel Primitives Under Docker

Docker isn't magic — it uses standard Linux kernel features:

### Namespaces (Isolation)

**Namespaces** give each container its own isolated view of system resources:

| Namespace | What It Isolates | Effect |
|---|---|---|
| **PID** | Process IDs | Container sees only its own processes; PID 1 inside ≠ PID 1 on host |
| **NET** | Network stack | Container has its own interfaces, routing table, iptables rules |
| **MNT** | Filesystem mounts | Container has its own root filesystem (`/`) |
| **UTS** | Hostname | Container can have its own hostname |
| **IPC** | Inter-process communication | Containers can't share memory segments |
| **USER** | User/group IDs | Root inside container ≠ root on host (with user namespaces) |

When Caddy runs `reverse_proxy caktus-portainer:9000`, it's talking across network namespaces — Caddy's NET namespace connects to Portainer's NET namespace through the Docker bridge.

### cgroups (Resource Limits)

**Control Groups (cgroups)** limit how much CPU, memory, and I/O a container can use:

```bash
# Limit a container to 512MB RAM and 0.5 CPU cores:
docker run --memory=512m --cpus=0.5 myimage
```

Caktus doesn't set explicit resource limits (the laptop has plenty for personal use), but cgroups prevent a runaway container from consuming all host resources if you configure them.

### Union Filesystems (Efficiency)

Docker images are built in **layers**. When you run 5 containers from `nginx:alpine`, they all share the same base image layers. Only the writable layer (container-specific changes) is unique:

```
nginx:alpine image layers (shared, read-only):
  Layer 1: Alpine Linux base (5 MB)
  Layer 2: Nginx binary (2 MB)
  Layer 3: Default config (1 KB)

Container 1 writable layer: access.log, custom config
Container 2 writable layer: access.log, custom config

Total disk for 2 containers: ~7 MB (shared) + 2 × container data
NOT: 14 MB (2 copies of everything)
```

---

## 4. The caktus-net Bridge Network

### What Is a Bridge Network?

A Docker bridge network is a **virtual Layer 2 switch** inside the kernel. Containers connected to the same bridge can communicate as if they were on the same physical network segment.

```
Docker Host (your laptop):
┌───────────────────────────────────────────────────────┐
│                                                        │
│  Physical NIC (eth0/wlan0)                            │
│  └── 192.168.1.100 (LAN IP)                          │
│                                                        │
│  WireGuard (wg0)                                      │
│  └── 10.0.0.2 (VPN IP)                               │
│                                                        │
│  Docker Bridge (br-xxxxxx → caktus-net)               │
│  └── 172.20.0.1 (bridge gateway)                      │
│      │                                                 │
│      ├── veth1 ↔ caktus-caddy     172.20.0.2          │
│      ├── veth2 ↔ caktus-portainer 172.20.0.3          │
│      ├── veth3 ↔ caktus-uptime   172.20.0.4           │
│      ├── veth4 ↔ caktus-landing  172.20.0.5           │
│      ├── veth5 ↔ caktus-hello    172.20.0.6           │
│      └── veth6 ↔ caktus-duckdns  172.20.0.7           │
│                                                        │
└───────────────────────────────────────────────────────┘
```

Each container gets a **veth pair** (virtual Ethernet cable):
- One end is inside the container's network namespace (appears as `eth0`)
- The other end is attached to the bridge on the host

### Why a Custom Bridge? (Not the Default Bridge)

Docker's default bridge network (`docker0`) has limitations:

| Feature | Default Bridge (`docker0`) | Custom Bridge (`caktus-net`) |
|---|---|---|
| Container DNS | ❌ Not available | ✅ Containers resolve by name |
| Network isolation | ❌ All containers share it | ✅ Only joined containers communicate |
| Custom subnet | ❌ Docker chooses | ✅ We specify `172.20.0.0/16` |
| Automatic service discovery | ❌ No | ✅ Yes |

On the default bridge, `ping caktus-portainer` fails — you'd need to find and use the IP manually. On `caktus-net`, Docker's embedded DNS resolves container names automatically.

### Custom Subnet Configuration

```yaml
networks:
  caktus-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
```

- `driver: bridge` — use the built-in bridge driver (virtual switch)
- `subnet: 172.20.0.0/16` — a /16 provides 65,534 usable IPs (more than enough for any personal server)
- We chose `172.20.0.0/16` to avoid conflicts with Docker's default `172.17.0.0/16` and home LANs (`192.168.x.x`)

---

## 5. Docker DNS: Container Name Resolution

### How It Works

Docker runs an **embedded DNS server** at `127.0.0.11` inside each container on user-defined bridge networks. When a container queries DNS for another container's name, Docker's DNS returns its IP on the bridge:

```
Inside caktus-caddy container:

$ nslookup caktus-portainer
Server:    127.0.0.11     ← Docker's embedded DNS
Address:   127.0.0.11:53

Name:      caktus-portainer
Address:   172.20.0.3     ← Portainer's IP on caktus-net
```

### Why This Matters for Caktus

The Caddyfile uses container names directly:

```caddyfile
reverse_proxy caktus-portainer:9000
```

Caddy doesn't know (or care) that Portainer's IP is `172.20.0.3`. Docker DNS resolves it. If a container restarts and gets a new IP (e.g., `172.20.0.8`), Docker DNS automatically updates the mapping. Caddy doesn't need a reload.

### Container Name = DNS Name

The `container_name` directive in `docker-compose.yml` sets both the container's hostname and its DNS name:

```yaml
portainer:
  container_name: caktus-portainer    # ← This becomes the DNS name
```

Without `container_name`, Docker generates a random name like `caktus-portainer-1`, which is unpredictable. By setting explicit names, we get stable, predictable DNS entries.

---

## 6. Port Binding & Isolation

### The Gateway Pattern

Only `caktus-caddy` exposes ports to the host:

```yaml
caddy:
  ports:
    - '80:80'      # host port 80 → container port 80
    - '443:443'    # host port 443 → container port 443
```

Every other container runs with **no port bindings**:

```yaml
portainer:
  # No 'ports:' section!
  # Port 9000 exists INSIDE the container
  # But is NOT accessible from the host network
```

### What "No Port Binding" Means

```
Without port binding:
  External request to laptop:9000  → ❌ Connection refused
  Docker bridge: caddy → portainer:9000  → ✅ Works

With port binding (ports: ['9000:9000']):
  External request to laptop:9000  → ✅ Reaches Portainer directly!
  Bypasses Caddy, bypasses auth, bypasses logging
  → This is a SECURITY HOLE
```

Port isolation ensures:
1. **No direct access**: You can't reach Portainer, Uptime Kuma, or any app by typing `laptop-ip:port`
2. **Caddy is the enforcer**: All external traffic must go through Caddy's routing rules
3. **Attack surface reduction**: Port scanners against the laptop find only ports 80, 443, 22, and 51820

### How Traffic Reaches Containers

```
External request → Caddy (port 80) → Docker bridge → Container (internal port)

The chain:
  1. WireGuard delivers packet to wg0 (10.0.0.2:80)
  2. iptables DNAT: port 80 → caktus-caddy container
  3. Caddy reads Host header, selects backend
  4. Docker DNS resolves container name → bridge IP
  5. Caddy connects to container's internal port via bridge
  6. Container processes request on its internal port (9000, 3001, etc.)
```

---

## 7. Docker Compose: Multi-Container Orchestration

### What Is Docker Compose?

Docker Compose is a tool for defining and running multi-container Docker applications. Instead of running `docker run` with 10+ flags for each container, you define everything in `docker-compose.yml` and run `docker compose up -d`.

### Compose v2 (Important!)

Caktus uses Docker Compose **v2** (the `docker compose` plugin):

```bash
# ✅ Correct (Compose v2 — plugin)
docker compose up -d

# ❌ Wrong (Compose v1 — standalone binary, deprecated)
docker-compose up -d
```

V2 is faster, supports more features, and is the maintained version. V1 is deprecated and no longer receives updates.

### Key Compose Commands

| Command | What It Does |
|---|---|
| `docker compose up -d` | Create and start all services in background |
| `docker compose up -d myapp` | Start only the `myapp` service |
| `docker compose down` | Stop and remove all containers (preserves volumes) |
| `docker compose pull` | Pull latest images for all services |
| `docker compose ps` | Show status of all services |
| `docker compose logs -f` | Follow logs from all services |
| `docker compose logs -f myapp` | Follow logs for one service |
| `docker compose restart myapp` | Restart a specific service |
| `docker compose exec caddy sh` | Open a shell inside a running container |

### The `-d` Flag

`-d` means "detached" — containers run in the background. Without it, Compose occupies your terminal and shows logs interactively. For a server, you always want `-d`.

---

## 8. Volumes & Data Persistence

### The Problem: Containers Are Ephemeral

Container filesystems are temporary. When a container is removed (`docker compose down`), everything inside it is deleted — including databases, config files, and user data.

```
Without volumes:
  1. Start Portainer → configure admin user
  2. docker compose down
  3. docker compose up -d
  4. Portainer: "Welcome! Set up admin user" ← data is GONE

With volumes:
  1. Start Portainer → data stored in portainer_data volume
  2. docker compose down  (volume is NOT deleted)
  3. docker compose up -d
  4. Portainer: "Welcome back, admin!" ← data persists
```

### Named Volumes vs Bind Mounts

Caktus uses both:

**Named Volumes** (managed by Docker):

```yaml
volumes:
  portainer_data:    # Docker creates and manages this
  uptime_data:       # Location: /var/lib/docker/volumes/caktus_portainer_data/_data
  caddy_data:
  caddy_config:
```

Pros:
- Docker manages location, permissions, and lifecycle
- Easy to back up: `docker volume ls`, `docker volume inspect`
- Cross-platform compatible

**Bind Mounts** (host directory mapped into container):

```yaml
caddy:
  volumes:
    - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro    # bind mount

landing:
  volumes:
    - ./apps/landing:/usr/share/nginx/html:ro        # bind mount
```

Pros:
- File is on your filesystem — easy to edit with any editor
- Version controlled (in your git repo)
- `:ro` flag makes it read-only inside the container (security)

### Volume Lifecycle

| Action | Named Volume | Bind Mount |
|---|---|---|
| `docker compose up -d` | Created if missing | Host dir must exist |
| `docker compose down` | **Preserved** | Host files untouched |
| `docker compose down -v` | **DELETED!** ⚠ | Host files untouched |
| Container restart | Preserved | Preserved |
| `docker volume prune` | Deleted if unused | Not affected |

**Critical**: Never run `docker compose down -v` unless you intend to delete all data. The `-v` flag removes named volumes.

### Caktus Volume Strategy

| Volume | Type | Contains | Backed Up? |
|---|---|---|---|
| `portainer_data` | Named volume | Portainer DB, settings | ✅ backup.sh |
| `uptime_data` | Named volume | Monitor configs, history | ✅ backup.sh |
| `caddy_data` | Named volume | TLS state (not critical) | ✅ backup.sh |
| `caddy_config` | Named volume | Caddy auto-config | ✅ backup.sh |
| `./caddy/Caddyfile` | Bind mount | Routing config | ✅ In git repo |
| `./apps/landing/` | Bind mount | Landing page HTML | ✅ In git repo |
| Docker socket | Bind mount | Docker API access (Portainer) | N/A |

---

## 9. Images & Layers

### How Images Are Built

A Docker image is a stack of read-only layers, built from a `Dockerfile`:

```dockerfile
FROM alpine:3.18          # Layer 1: Alpine Linux base (~5 MB)
RUN apk add nginx         # Layer 2: Install Nginx (~2 MB)
COPY nginx.conf /etc/     # Layer 3: Copy config (~1 KB)
COPY index.html /var/www/ # Layer 4: Copy content (~5 KB)
```

Each instruction creates a new layer. Layers are cached — if you change `index.html`, only Layer 4 is rebuilt. Layers 1–3 are reused from cache.

### Image Tags

```yaml
image: caddy:alpine        # tag = "alpine"
image: portainer/portainer-ce:latest  # tag = "latest"
image: nginx:alpine        # tag = "alpine"
```

| Tag | Meaning | Best Practice |
|---|---|---|
| `latest` | Most recent version | ⚠ Can change unexpectedly |
| `alpine` | Alpine Linux-based (small) | ✅ Good for size-constrained environments |
| `v1.2.3` | Specific version | ✅ Best for reproducibility |

Caktus uses `:latest` or `:alpine` for simplicity. In production, you'd pin versions to prevent surprise updates.

### Image Sources

| Image | Source | Size |
|---|---|---|
| `caddy:alpine` | Docker Hub (official) | ~40 MB |
| `portainer/portainer-ce:latest` | Docker Hub (Portainer team) | ~90 MB |
| `louislam/uptime-kuma:latest` | Docker Hub (community) | ~150 MB |
| `nginx:alpine` | Docker Hub (official) | ~25 MB |
| `nginxdemos/hello` | Docker Hub (Nginx demo) | ~15 MB |
| `lscr.io/linuxserver/duckdns` | LinuxServer.io registry | ~15 MB |

---

## 10. The Container Lifecycle

```
Image                     Container
  │                          │
  │  docker compose up -d    │
  ├─────────────────────────▶  Created
  │                          │
  │                          ▼
  │                        Running ◀──── docker compose start
  │                          │
  │                          │  docker compose stop
  │                          │  (or crash, or OOM kill)
  │                          ▼
  │                        Stopped ◀──── docker compose restart
  │                          │
  │                          │  docker compose down
  │                          ▼
  │                        Removed (volume data preserved)
```

### Restart Policies

Every Caktus container uses `restart: unless-stopped`:

```yaml
restart: unless-stopped
```

This means:
- Container restarts automatically if it crashes
- Container restarts after a host reboot (if Docker is enabled at boot)
- Container does NOT restart if you manually stopped it (`docker compose stop`)

| Policy | Restart on Crash? | Restart on Reboot? | Restart After `docker stop`? |
|---|---|---|---|
| `no` | ❌ | ❌ | ❌ |
| `on-failure` | ✅ | ❌ | ❌ |
| `unless-stopped` | ✅ | ✅ | ❌ |
| `always` | ✅ | ✅ | ✅ |

`unless-stopped` is the right choice for Caktus — automatic recovery from crashes and reboots, but you can still manually stop services for maintenance.

---

## 11. Health Checks

Docker health checks let you monitor whether a container is actually working (not just running):

```yaml
caddy:
  healthcheck:
    test: ["CMD", "wget", "-qO-", "http://localhost:80"]
    interval: 30s
    timeout: 5s
    retries: 3
```

| Parameter | Meaning |
|---|---|
| `test` | Command to run inside the container. Exit 0 = healthy; exit 1 = unhealthy. |
| `interval` | How often to run the check (every 30 seconds). |
| `timeout` | Maximum time the check can take before being considered failed. |
| `retries` | How many consecutive failures before marking as unhealthy. |

### Health Status

```bash
$ docker compose ps
NAME              STATUS                   PORTS
caktus-caddy      Up 3 hours (healthy)     0.0.0.0:80->80/tcp
caktus-portainer  Up 3 hours               
caktus-uptime     Up 3 hours               
```

The `(healthy)` indicator shows the health check is passing. If it shows `(unhealthy)`, Caddy is running but not responding on port 80.

### Why It Matters

A container can be "running" (process exists) but "unhealthy" (not serving traffic). Without health checks, `docker compose ps` would show "Up" even if the app has crashed internally. Health checks catch:
- Application deadlocks
- Database connection failures
- Out-of-memory conditions (partial)
- Misconfigured services

---

## 12. The Caktus Docker Patterns

### Pattern 1: The Gateway Container

```yaml
caddy:
  image: caddy:alpine
  container_name: caktus-caddy
  ports:
    - '80:80'
    - '443:443'
  volumes:
    - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
  networks:
    - caktus-net
  restart: unless-stopped
```

Only one container gets `ports:`. It's the gateway — all external traffic enters through it. Everything else is internal.

### Pattern 2: The Internal Service

```yaml
portainer:
  image: portainer/portainer-ce:latest
  container_name: caktus-portainer
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
    - portainer_data:/data
  networks:
    - caktus-net
  restart: unless-stopped
```

No `ports:` — only reachable through the gateway (Caddy). Uses named volumes for persistence. Explicit `container_name` for DNS resolution.

### Pattern 3: The Sidecar Service

```yaml
duckdns:
  image: lscr.io/linuxserver/duckdns:latest
  container_name: caktus-duckdns
  environment:
    - SUBDOMAINS=${DUCKDNS_SUBDOMAIN}
    - TOKEN=${DUCKDNS_TOKEN}
  networks:
    - caktus-net
  restart: unless-stopped
```

Not accessible via web. No ports, no volumes. Runs a background task (updating DuckDNS IP). Still on `caktus-net` because it needs outbound internet access via the Docker bridge.

### Pattern 4: Adding a New App

```yaml
myapp:
  image: myimage:tag
  container_name: caktus-myapp
  networks:
    - caktus-net
  restart: unless-stopped
```

Minimal config: image, name, network, restart policy. The `add-app.sh` script generates exactly this block. Optional additions:
- `volumes:` for persistent data
- `environment:` for configuration
- `healthcheck:` for monitoring

---

## 13. docker-compose.yml Walkthrough

The Caktus `docker-compose.yml` follows a structured layout:

```yaml
version: '3.9'                    # Compose file format version
```

### Networks Section

```yaml
networks:
  caktus-net:                      # Network name
    driver: bridge                 # Virtual Layer 2 switch
    ipam:
      config:
        - subnet: 172.20.0.0/16   # Custom subnet (avoids conflicts)
```

Defined once, referenced by every service via `networks: [caktus-net]`.

### Services Section

Services are defined in dependency order:
1. **DuckDNS** — keeps DNS updated (foundational)
2. **Caddy** — reverse proxy (gateway)
3. **Portainer** — Docker management (operational tool)
4. **Uptime Kuma** — monitoring (operational tool)
5. **Landing** — project showcase (app)
6. **Hello** — smoke test (app)
7. **Your apps** — below the marker comment

### Volumes Section

```yaml
volumes:
  caddy_data:
  caddy_config:
  portainer_data:
  uptime_data:
```

Named volumes are declared globally and referenced in service `volumes:` sections. Docker creates them automatically on first `docker compose up`.

### Environment Variables

```yaml
environment:
  - SUBDOMAINS=${DUCKDNS_SUBDOMAIN}    # from .env file
  - TOKEN=${DUCKDNS_TOKEN}              # from .env file
```

The `${VAR}` syntax reads from the `.env` file in the same directory. This keeps secrets out of the Compose file (which is committed to git).

---

## 14. Troubleshooting Docker

### Container Won't Start

```bash
# Check what happened
docker compose logs myapp

# Common causes:
# - Image not found (typo in image name)
# - Port conflict (another process using the port)
# - Volume mount failure (host path doesn't exist)
# - Environment variable missing
```

### Container Keeps Restarting

```bash
# Check restart count
docker inspect caktus-myapp --format='{{.RestartCount}}'

# Check logs for crash reason
docker compose logs --tail 50 myapp

# Common causes:
# - App crashes on startup (missing config, DB not ready)
# - OOM kill (container exceeds memory limit)
# - Dependency not available (DB container not started yet)
```

### Can't Connect to Container

```bash
# 1. Is the container running?
docker compose ps myapp

# 2. Is the container on caktus-net?
docker inspect caktus-myapp --format='{{json .NetworkSettings.Networks}}'

# 3. Can Caddy reach it?
docker exec caktus-caddy wget -qO- http://caktus-myapp:3000

# 4. Is the app actually listening?
docker exec caktus-myapp ss -tlnp
```

### Disk Space Issues

```bash
# Check Docker disk usage
docker system df

# Clean up unused images (safe)
docker image prune -f

# Clean up everything unused (more aggressive)
docker system prune -f

# WARNING: This deletes unused volumes (DATA LOSS!)
docker system prune --volumes  # ← NEVER run this casually
```

### Viewing Container Resources

```bash
# Live resource usage
docker stats

# One-time snapshot
docker stats --no-stream

# Output:
# CONTAINER       CPU %   MEM USAGE / LIMIT   NET I/O
# caktus-caddy    0.05%   15.2MiB / 7.7GiB    1.2GB / 800MB
# caktus-portainer 0.10%  45.3MiB / 7.7GiB    500MB / 200MB
```

### Inspecting a Running Container

```bash
# Open a shell inside a container
docker exec -it caktus-caddy sh

# Run a single command
docker exec caktus-caddy cat /etc/caddy/Caddyfile

# Check container's environment variables
docker exec caktus-duckdns env | grep TOKEN

# Check container's network configuration
docker exec caktus-caddy ip addr show
```

---

## Key Takeaways

1. **Containers share the host kernel** — ~10× less overhead than VMs
2. **caktus-net** is a custom bridge providing DNS, isolation, and a known subnet
3. **Docker DNS** resolves container names automatically — no manual IP management
4. **Only Caddy binds host ports** — all other containers are network-invisible from outside
5. **Named volumes** persist data across container restarts and removal
6. **Bind mounts** (`:ro`) map host files into containers read-only (for config files)
7. **`restart: unless-stopped`** provides automatic crash and reboot recovery
8. **Docker Compose v2** (`docker compose`, not `docker-compose`) manages the full stack
9. **Health checks** distinguish "container is running" from "container is working"
10. **The `add-app.sh` pattern** is minimal: image + name + network + restart = done

---

*Part of Project Caktus documentation suite*
