# 🌵 Caktus Operational Runbook

> Day-to-day operations, troubleshooting, and maintenance guide.

---

## Quick Reference

| Task | Command |
|---|---|
| Start all services | `cd ~/caktus && docker compose up -d` |
| Stop all services | `docker compose down` |
| Restart a service | `docker compose restart <service>` |
| View all logs | `docker compose logs -f` |
| View service logs | `docker compose logs -f <service>` |
| Reload Caddy config | `docker exec caktus-caddy caddy reload --config /etc/caddy/Caddyfile` |
| WireGuard status | `sudo wg show` |
| Restart WireGuard | `sudo systemctl restart wg-quick@wg0` |
| Run health check | `bash ~/caktus/scripts/health-check.sh` |
| Add a new app | `bash ~/caktus/scripts/add-app.sh <name> <port> <image>` |
| Check service status | `docker compose ps` |
| Container resource usage | `docker stats` |

---

## Adding a New Application

### Automated (recommended)

```bash
bash ~/caktus/scripts/add-app.sh myapp 3000 myimage:latest
```

App is live at `https://myapp.caktus.duckdns.org` immediately.

### Manual (to understand what's happening)

**Step 1 — `docker-compose.yml`:** Add before the `volumes:` block:

```yaml
  myapp:
    image: myimage:latest
    container_name: caktus-myapp
    networks:
      - caktus-net
    restart: unless-stopped
```

**Step 2 — `caddy/Caddyfile`:** Add inside the `:80 {` block, before `handle {`:

```caddyfile
    @myapp host myapp.caktus.duckdns.org
    handle @myapp {
        reverse_proxy caktus-myapp:3000
    }
```

**Step 3 — Apply:**

```bash
cd ~/caktus
docker compose up -d
docker exec caktus-caddy caddy reload --config /etc/caddy/Caddyfile
```

---

## Troubleshooting Guide

### URL connection refused / can't reach app

```bash
# 1. Check WireGuard tunnel first
sudo wg show
ping -c 4 10.0.0.1

# 2. Restart tunnel if needed
sudo systemctl restart wg-quick@wg0

# 3. Check Docker services
docker compose ps
docker compose up -d
```

### 502 Bad Gateway

The app container is not running or crashed.

```bash
docker compose ps                    # find the failing service
docker compose logs -f myapp        # check why it crashed
docker compose up -d myapp          # restart it
```

### 404 on a valid subdomain

The Caddyfile route is missing or the Host matcher is wrong.

```bash
# Check Caddyfile for typos
cat ~/caktus/caddy/Caddyfile | grep "host myapp"

# Reload after fixing
docker exec caktus-caddy caddy reload --config /etc/caddy/Caddyfile
```

### TLS certificate errors

```bash
# On VPS — check Caddy's cert issuance logs
sudo journalctl -fu caddy | grep -iE 'cert|tls|acme|duckdns'

# Common causes:
# - Invalid DuckDNS token in VPS Caddyfile
# - Rate limited by Let's Encrypt (wait 1 hour)
# - DNS not pointing to VPS yet (check dig caktus.duckdns.org)
```

### WireGuard tunnel silently drops

```bash
sudo wg show                         # check last handshake time
sudo systemctl status wg-quick@wg0
sudo systemctl restart wg-quick@wg0  # usually fixes it

# If still broken, check VPS side:
# ssh ubuntu@<VPS_IP> "sudo wg show"
```

### Everything is broken — nuclear reset

```bash
sudo systemctl restart wg-quick@wg0   # 1. Fix tunnel
cd ~/caktus && docker compose up -d   # 2. Restart all containers
bash scripts/health-check.sh          # 3. Verify
```

---

## Hackathon Deployment Checklist

### Night Before

- [ ] Run `bash scripts/health-check.sh` — all green
- [ ] `docker compose pull` — pull latest images
- [ ] Test your app URL on mobile data (disable WiFi!)
- [ ] Save DuckDNS token somewhere accessible
- [ ] Laptop plugged into power

### Day of Demo

```bash
cd ~/caktus && docker compose up -d
bash scripts/health-check.sh
```

- [ ] Open your app URL — confirm it loads
- [ ] Share: `https://demo.caktus.duckdns.org`
- [ ] Judges click from any device, any network ✅

### If Something Breaks

| Step | Command | Fixes |
|---|---|---|
| 1 | `sudo systemctl restart wg-quick@wg0` | 80% of issues |
| 2 | `docker compose restart` | Container crashes |
| 3 | `docker compose logs -f` | Find root cause |
| Nuclear | Reboot laptop, then `docker compose up -d` | Everything |

---

## Routine Maintenance

### Weekly

```bash
# Check disk space
df -h /

# Check memory
free -h

# Check for container restarts
docker compose ps

# Update images (apply during low-traffic time)
docker compose pull
docker compose up -d
```

### Monthly

```bash
# Prune unused Docker images (free disk space)
docker image prune -f

# Check WireGuard — confirm handshakes are healthy
sudo wg show

# Verify TLS cert expiry on VPS
# sudo journalctl -u caddy | grep -i "certificate"
```

---

## Environment Variables Reference

All secrets in `~/caktus/.env`:

| Variable | Description |
|---|---|
| `DUCKDNS_TOKEN` | Token from duckdns.org account page |
| `DUCKDNS_SUBDOMAIN` | Your subdomain (e.g. `caktus`) |
| `VPS_IP` | Oracle VPS public IP address |

---

## App-Specific Notes

<!-- Add notes per app as you add them -->
<!-- Example:
### portainer
- First login: go to https://portainer.caktus.duckdns.org, create admin user within 5 minutes of start
- If locked out: docker compose restart portainer

### myapp
- Config at: ~/caktus/apps/myapp/.env
-->
