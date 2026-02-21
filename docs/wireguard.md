# WireGuard Protocol Deep Dive
## How the Caktus VPN Tunnel Works at Every Level

> WireGuard is the backbone of Caktus — without it, nothing works.
> This document explains the protocol, the cryptography, and every line of your config.

---

## Table of Contents

1. [What WireGuard Actually Is](#1-what-wireguard-actually-is)
2. [Why WireGuard Over Other VPNs](#2-why-wireguard-over-other-vpns)
3. [How WireGuard Punches Through NAT](#3-how-wireguard-punches-through-nat)
4. [The Cryptographic Stack](#4-the-cryptographic-stack)
5. [Key Exchange & the Noise Protocol](#5-key-exchange--the-noise-protocol)
6. [Data Encryption: ChaCha20-Poly1305](#6-data-encryption-chacha20-poly1305)
7. [Packet Format](#7-packet-format)
8. [The wg0 Virtual Interface](#8-the-wg0-virtual-interface)
9. [AllowedIPs: More Than You Think](#9-allowedips-more-than-you-think)
10. [PersistentKeepalive: Fighting NAT Expiry](#10-persistentkeepalive-fighting-nat-expiry)
11. [Laptop Config Line-by-Line](#11-laptop-config-line-by-line)
12. [VPS Config Line-by-Line](#12-vps-config-line-by-line)
13. [Key Management & Security](#13-key-management--security)
14. [Troubleshooting WireGuard](#14-troubleshooting-wireguard)

---

## 1. What WireGuard Actually Is

WireGuard is a **Layer 3 VPN protocol** that creates a virtual network interface (`wg0`) on each machine. When you send a packet to a WireGuard address (like `10.0.0.1`), the operating system routes it to the `wg0` interface. WireGuard encrypts the packet and sends it as a UDP datagram over the real physical network to the target peer.

On the receiving end, WireGuard decrypts the packet and delivers it to the local `wg0` interface — as if the two machines were directly connected.

```
Application sends to 10.0.0.1
  │
  ▼
OS routing table: 10.0.0.1 → wg0
  │
  ▼
WireGuard on wg0:
  1. Looks up: which peer handles 10.0.0.1? → VPS peer
  2. Encrypts inner packet with peer's session key (ChaCha20-Poly1305)
  3. Wraps in UDP: src=laptop:random → dst=VPS_PUBLIC_IP:51820
  │
  ▼
Physical NIC sends UDP over the internet
  │
  ▼
VPS receives UDP on port 51820
  1. WireGuard decrypts with session key
  2. Verifies Poly1305 MAC (authenticity check)
  3. Delivers inner packet to wg0 interface
  │
  ▼
VPS OS delivers packet to 10.0.0.1 → local application (Caddy)
```

### What WireGuard Is NOT

- **Not a userspace application** — it runs as a Linux kernel module, making it extremely fast
- **Not configurable in crypto** — algorithms are fixed, no cipher suite negotiation
- **Not a full VPN product** — no user management, no GUI, no built-in DNS, no IP allocation
- **Not chatty** — a WireGuard interface with no traffic sends zero packets (except keepalives if configured)

---

## 2. Why WireGuard Over Other VPNs

### Comparison

| Feature | WireGuard | OpenVPN | IPsec |
|---|---|---|---|
| **Codebase** | ~4,000 lines | ~100,000 lines | ~400,000 lines |
| **Transport** | UDP only | TCP or UDP | ESP (IP protocol 50) |
| **Encryption** | ChaCha20-Poly1305 (fixed) | Configurable (many options) | Configurable |
| **Handshake** | 1-RTT (Noise protocol) | Multi-RTT | Multi-RTT (IKEv2) |
| **Key format** | Curve25519 public keys | X.509 certificates | X.509 or PSK |
| **Kernel module** | Yes (in-tree since Linux 5.6) | No (userspace) | Yes |
| **Lines of config** | ~10 | ~50 | ~100+ |
| **Audit surface** | Trivially auditable | Complex | Very complex |

### Why These Differences Matter for Caktus

1. **4,000 lines of code** — code that can be audited in a day. OpenVPN's 100K+ lines have had critical CVEs; WireGuard's attack surface is minimal.

2. **UDP-only** — this is a feature, not a limitation. UDP is easier to punch through NAT (no 3-way handshake that NAT middleboxes can interfere with). TCP-based VPNs suffer from **TCP-over-TCP meltdown** — when WireGuard carries TCP traffic inside the tunnel, TCP handles retransmission at the inner layer, while UDP at the outer layer doesn't try to retransmit duplicate packets.

3. **Kernel module** — WireGuard processes packets in kernel space. OpenVPN has to copy packets between kernel and userspace on every message. This gives WireGuard significantly better throughput and lower latency.

4. **No cipher negotiation** — this eliminates downgrade attacks. With OpenVPN, a MITM could theoretically force both sides to use a weak cipher. WireGuard uses one set of algorithms, period.

---

## 3. How WireGuard Punches Through NAT

This is the critical mechanism that makes Caktus possible.

### The NAT Problem Recap

Your laptop is behind (at least) two layers of NAT:
1. Home router NAT (`192.168.1.x` → router's "public" IP)
2. ISP CGNAT (`100.64.x.x` → ISP's actual public IP)

Inbound connections fail because there's no NAT table entry for them. But outbound connections *create* NAT table entries.

### How WireGuard Uses Outbound UDP

```
Timeline:
═════════

t=0s: Laptop starts WireGuard
  Laptop sends UDP SRC=192.168.1.100:random → DST=VPS_IP:51820
  Home router NAT: rewrites SRC → HomeRouterIP:11111
  CGNAT NAT: rewrites SRC → PublicIP:22222
  
  NAT tables now have entries:
    Home Router: [192.168.1.100:random ↔ HomeRouterIP:11111]
    CGNAT:       [HomeRouterIP:11111  ↔ PublicIP:22222]

  VPS receives from PublicIP:22222
  VPS WireGuard: "new peer at PublicIP:22222" (records as endpoint)

t=1s: VPS needs to send traffic to laptop
  VPS sends UDP SRC=VPS_IP:51820 → DST=PublicIP:22222
  CGNAT: matches NAT table entry → forwards to HomeRouterIP:11111
  Home Router: matches NAT table entry → forwards to 192.168.1.100:random
  
  ✅ Packet reaches laptop through both NAT layers!

t=30s: NAT tables expire if no traffic flows
  → PersistentKeepalive prevents this (see section 10)
```

### Why UDP Works Better Than TCP for NAT Traversal

TCP NAT traversal requires the NAT device to track connection state (SYN, ACK, FIN). Many CGNAT devices aggressively time out idle TCP states. UDP is stateless — NAT devices just need a simple `src:port ↔ dst:port` mapping with a timer. This mapping is:
- Simpler to maintain
- Less likely to be broken by intermediate devices
- Easier to keep alive with small keepalive packets

---

## 4. The Cryptographic Stack

WireGuard uses a carefully chosen set of modern cryptographic primitives:

```
┌─────────────────────────────────────────────────────┐
│                  WireGuard Crypto Stack               │
├─────────────────────────────────────────────────────┤
│                                                       │
│  Handshake Protocol:  Noise_IKpsk2                   │
│    Key Agreement:     Curve25519 (ECDH)              │
│    Identity:          Static Curve25519 key pairs     │
│    Pre-shared Key:    Optional (extra quantum safety) │
│                                                       │
│  Data Encryption:     ChaCha20-Poly1305 (AEAD)       │
│    Cipher:            ChaCha20 (stream cipher)        │
│    Authentication:    Poly1305 (MAC)                  │
│                                                       │
│  Key Derivation:      BLAKE2s (hash function)         │
│    Derive session keys from handshake output          │
│                                                       │
│  Cookies:             BLAKE2s-MAC                     │
│    DoS protection at the protocol level               │
│                                                       │
└─────────────────────────────────────────────────────┘
```

None of these are optional. You can't configure WireGuard to use AES, RSA, or SHA-256. This is intentional — **one good set of algorithms, no negotiation, no downgrade attacks.**

---

## 5. Key Exchange & the Noise Protocol

### What Is Noise?

Noise is a framework for building cryptographic handshake protocols. It was designed by Trevor Perrin (co-creator of the Signal Protocol). WireGuard uses a specific Noise pattern called **Noise_IKpsk2**.

Let's decode this name:
- **I**: The *initiator* (laptop) sends its static public key in the first message
- **K**: The *responder's* (VPS) static public key is pre-known to the initiator
- **psk2**: An optional pre-shared key is mixed in at step 2

### The Handshake (1-RTT)

The entire handshake completes in **one round trip** — one message from initiator, one response from responder:

```
Laptop (Initiator)                     VPS (Responder)
──────────────────                     ────────────────

Knows: VPS's public key (from config)
       Own private key

  ┌──────────────────────────────┐
  │ HANDSHAKE INITIATION         │
  │                              │
  │ Ephemeral DH key pair        │
  │ DH(ephemeral, VPS_static)    │──────────────────▶
  │ DH(static, VPS_static)       │    
  │ Encrypted(laptop_static_pub) │
  │ Timestamp (anti-replay)      │
  └──────────────────────────────┘

                                    VPS decrypts:
                                      Extracts laptop's static public key
                                      Verifies: is this an authorized peer?
                                      Generates own ephemeral key pair

                                    ┌──────────────────────────────┐
                                    │ HANDSHAKE RESPONSE           │
  ◀─────────────────────────────────│                              │
                                    │ Ephemeral DH key pair        │
                                    │ DH(vps_ephemeral, laptop_*)  │
                                    │ Nothing else needed!         │
                                    └──────────────────────────────┘

Both sides now derive:
  Transport key (send) + Transport key (receive)
  Using BLAKE2s KDF over all DH results

══════════════════════════════════════════════════════
         DATA TRANSPORT (ChaCha20-Poly1305)
══════════════════════════════════════════════════════
```

### Forward Secrecy

Each handshake generates new **ephemeral** key pairs. The session keys are derived from Diffie-Hellman operations involving these ephemeral keys. Even if a peer's static private key is later compromised, past session keys cannot be derived — the ephemeral keys were destroyed and were never stored.

WireGuard re-keys automatically every **2 minutes** or after **2^64 messages** (whichever comes first). This limits the window of vulnerability if a session key is somehow compromised.

---

## 6. Data Encryption: ChaCha20-Poly1305

### ChaCha20: The Stream Cipher

ChaCha20 is a stream cipher designed by Daniel J. Bernstein. It generates a pseudorandom keystream from:
- A 256-bit key
- A 96-bit nonce (number used once)
- A 32-bit counter

The keystream is XORed with the plaintext to produce ciphertext. Decryption is the same operation — XOR ciphertext with keystream to get plaintext.

```
Keystream = ChaCha20(key, nonce, counter)
Ciphertext = Plaintext ⊕ Keystream
Plaintext  = Ciphertext ⊕ Keystream
```

**Why not AES?** AES requires hardware acceleration (AES-NI) to be fast. ChaCha20 is designed to be fast in software on any CPU — including the low-power ARM chips in Oracle's Always Free VMs and old laptop CPUs. On hardware without AES-NI, ChaCha20 is 3× faster than AES.

### Poly1305: The Authenticator

Encryption alone doesn't prevent tampering. An attacker who flips bits in the ciphertext flips the corresponding bits in the plaintext. Poly1305 generates a **Message Authentication Code (MAC)** — a 16-byte tag that proves:
1. The message was created by someone who knows the key
2. The message has not been modified in transit

Together, **ChaCha20-Poly1305** is an **AEAD (Authenticated Encryption with Associated Data)** construction — it encrypts AND authenticates in a single pass. If even one bit is changed, verification fails and the packet is silently dropped.

### Why This Matters for Caktus

Every packet flowing through the WireGuard tunnel is:
- **Confidential**: encrypted (ChaCha20) — ISP can't read it
- **Authenticated**: tagged (Poly1305) — nobody can tamper with it
- **Replay-protected**: nonce + counter prevent replaying old packets

---

## 7. Packet Format

A WireGuard data packet on the wire looks like this:

```
Outer IP + UDP Header (not encrypted — needed for routing):
┌──────────────────────────────────────────────────────┐
│ IP: SRC=laptop_IP  DST=VPS_IP                       │
│ UDP: SRC=random_port  DST=51820                      │
├──────────────────────────────────────────────────────┤
│ WireGuard Transport Data Message:                    │
│ ┌──────────────────────────────────────────────────┐ │
│ │ Type: 4 (transport data)                  4 bytes│ │
│ │ Receiver Index (which session)            4 bytes│ │
│ │ Counter (incrementing nonce)              8 bytes│ │
│ │ Encrypted Payload                        N bytes │ │
│ │   (ChaCha20-Poly1305 of inner IP packet)         │ │
│ │ Poly1305 Authentication Tag             16 bytes │ │
│ └──────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

The encrypted payload contains a full IP packet — with its own source (`10.0.0.2`) and destination (`10.0.0.1`) headers. This is the **encapsulation** — an IP packet inside a UDP packet inside an IP packet.

### Overhead

WireGuard adds ~60 bytes of overhead per packet (UDP header + WireGuard header + Poly1305 tag). For a typical 1500-byte MTU, this means about 4% overhead — negligible for most workloads.

---

## 8. The wg0 Virtual Interface

When WireGuard starts, it creates a virtual network interface called `wg0`:

```bash
$ ip addr show wg0
wg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN
    link/none
    inet 10.0.0.2/24 scope global wg0
```

Key observations:
- **POINTOPOINT**: This is a point-to-point link (like a cable between two machines)
- **NOARP**: No ARP needed (it's not an Ethernet segment)
- **mtu 1420**: 80 bytes less than standard 1500 — leaves room for WireGuard's UDP+encryption overhead
- **inet 10.0.0.2/24**: The laptop's VPN address

The OS treats `wg0` like any other network interface. You can ping through it, route through it, bind services to it. Caddy listening on `0.0.0.0:80` automatically accepts connections on `wg0` (10.0.0.2:80).

---

## 9. AllowedIPs: More Than You Think

`AllowedIPs` is the most misunderstood WireGuard concept. It serves **three purposes at once**:

### 1. Routing Rule (Outbound)

```
AllowedIPs = 10.0.0.1/32
```
Means: "Route any packet with destination 10.0.0.1 through this peer's tunnel."

WireGuard automatically adds a routing rule to the kernel:
```
10.0.0.1 via wg0
```

### 2. Access Control (Inbound)

The same `AllowedIPs` also means: "Only accept packets from this peer if the inner source IP is 10.0.0.1."

If the VPS sends a packet claiming to be from `10.0.0.99` through the tunnel, WireGuard drops it — because `10.0.0.99` isn't in `AllowedIPs` for that peer.

### 3. Full Tunnel vs Split Tunnel

```
AllowedIPs = 0.0.0.0/0    ← FULL tunnel (all traffic through VPN)
AllowedIPs = 10.0.0.1/32  ← SPLIT tunnel (only VPN traffic through VPN)
```

**Caktus uses split tunneling** (`10.0.0.1/32`). Only traffic destined for the VPS goes through the tunnel. Your laptop's regular internet (apt updates, browsing, etc.) uses the normal ISP connection. This is critical because:
- Oracle Free Tier bandwidth is limited (50 Mbps)
- Routing all traffic through VPS adds unnecessary latency
- The VPS shouldn't see your browsing traffic

---

## 10. PersistentKeepalive: Fighting NAT Expiry

### The Problem

NAT tables have timeouts. When no traffic flows through a NAT mapping for a while (typically 30–120 seconds), the router deletes the mapping. The next incoming packet from the VPS has no matching NAT entry and is silently dropped.

### The Solution

```
PersistentKeepalive = 25
```

This tells WireGuard: "If no packet has been sent in the last 25 seconds, send a keepalive packet (32 bytes of nothing)."

```
Timeline:
t=0s:   App traffic flows through tunnel
t=10s:  App finishes, no more traffic
t=25s:  WireGuard: no traffic for 25s → send keepalive
t=50s:  WireGuard: no traffic for 25s → send keepalive
...forever...

NAT mapping never expires because it sees a packet every 25 seconds.
```

### Why 25 Seconds?

- Most NAT devices timeout after 30–120 seconds for UDP
- 25 seconds gives a comfortable margin below the minimum (30s)
- The keepalive packet is only 32 bytes — 25s interval = ~77 bytes/minute = insignificant bandwidth

### Why Only the Laptop Needs It

The laptop is behind NAT. The VPS has a public IP — it doesn't need to maintain a NAT mapping. The VPS has `ListenPort = 51820` and is directly reachable. Only the NAT-traversing side needs keepalives.

---

## 11. Laptop Config Line-by-Line

```ini
[Interface]
Address = 10.0.0.2/24
PrivateKey = <LAPTOP_PRIVATE_KEY>
```

| Directive | Purpose |
|---|---|
| `Address = 10.0.0.2/24` | Assigns VPN IP `10.0.0.2` to `wg0`. The `/24` tells the OS the VPN subnet is `10.0.0.0–10.0.0.255`. |
| `PrivateKey` | The laptop's Curve25519 private key. Used to decrypt incoming packets and prove identity during handshake. **Never share this.** `chmod 600`. |

```ini
[Peer]
PublicKey = <VPS_PUBLIC_KEY>
Endpoint = <VPS_PUBLIC_IP>:51820
AllowedIPs = 10.0.0.1/32
PersistentKeepalive = 25
```

| Directive | Purpose |
|---|---|
| `PublicKey` | The VPS's public key. WireGuard uses this to encrypt outgoing packets to this peer and verify incoming packets from it. |
| `Endpoint` | Where to send encrypted UDP packets to reach this peer. The VPS's public IP and WireGuard port. |
| `AllowedIPs = 10.0.0.1/32` | Only route traffic to `10.0.0.1` through this tunnel (split tunneling). Only accept packets from this peer if they claim to be from `10.0.0.1`. |
| `PersistentKeepalive = 25` | Send a keepalive every 25 seconds to keep the NAT mapping alive. |

---

## 12. VPS Config Line-by-Line

```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <VPS_PRIVATE_KEY>
```

| Directive | Purpose |
|---|---|
| `Address = 10.0.0.1/24` | The VPS's VPN address. |
| `ListenPort = 51820` | Fixed UDP port to listen on. The firewall (iptables and Oracle security list) must allow inbound UDP on this port. |
| `PrivateKey` | The VPS's Curve25519 private key. |

```ini
# IP forwarding and NAT rules
PostUp   = sysctl -w net.ipv4.ip_forward=1
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp   = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp   = iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ens3 -j MASQUERADE
```

| Rule | Purpose |
|---|---|
| `ip_forward=1` | Enables the VPS kernel to forward packets between interfaces (wg0 ↔ ens3). Without this, packets arriving on wg0 destined for ens3 would be dropped. |
| `FORWARD -i wg0 -j ACCEPT` | Allow packets arriving from WireGuard tunnel to be forwarded. |
| `FORWARD -o wg0 -j ACCEPT` | Allow packets going into the WireGuard tunnel to be forwarded. |
| `MASQUERADE -o ens3` | NAT outbound traffic from the tunnel so it appears to come from the VPS's public IP. This is needed if laptop wants to reach the internet *through* the VPS (not used in Caktus's split tunnel setup, but included for flexibility). |
| `PostDown` rules | Clean up all iptables rules when WireGuard stops, preventing stale rules from accumulating. |

```ini
[Peer]
PublicKey = <LAPTOP_PUBLIC_KEY>
AllowedIPs = 10.0.0.2/32
```

| Directive | Purpose |
|---|---|
| `PublicKey` | The laptop's public key. Only this peer can connect. |
| `AllowedIPs = 10.0.0.2/32` | Only accept packets from this peer if they claim to be from `10.0.0.2`. Only route traffic to `10.0.0.2` through this peer. |

Note the VPS peer section has **no `Endpoint`** — the VPS doesn't know the laptop's public IP in advance (it's behind NAT). WireGuard learns the laptop's endpoint from the first incoming handshake packet and stores it dynamically. This is called **roaming** — if the laptop's ISP assigns a new IP, the next handshake packet comes from the new IP, and the VPS updates its stored endpoint automatically.

---

## 13. Key Management & Security

### Key Generation

```bash
# Generate a key pair
wg genkey | tee private.key | wg pubkey > public.key
```

This creates a **Curve25519** key pair:
- Private key: 32 bytes, base64-encoded (44 characters)
- Public key: derived from private key via Curve25519 scalar multiplication
- **One-way**: you cannot derive the private key from the public key

### Security Rules

| Rule | Command | Why |
|---|---|---|
| Private keys: `chmod 600` | `sudo chmod 600 /etc/wireguard/*.key` | Only root can read. Any user who reads this gains full tunnel access. |
| Private keys: never copy over network | Generate on the machine where they'll be used | Even encrypted transfer is a risk. |
| Config file: `chmod 600` | `sudo chmod 600 /etc/wireguard/wg0.conf` | Config contains the private key inline. |
| Public keys: share freely | They're designed to be public | Publishing your public key is safe — it's the same principle as SSH public keys. |

### Key Rotation

WireGuard doesn't have built-in key rotation. To rotate keys:
1. Generate new key pair on the laptop: `wg genkey | tee new.key | wg pubkey`
2. Update laptop's `wg0.conf` with new private key
3. Update VPS's `wg0.conf` with laptop's new public key
4. Restart WireGuard on both sides

In practice, key rotation is rarely needed because:
- Session keys rotate automatically every 2 minutes (forward secrecy)
- Static keys are only used for identity, not bulk encryption
- The risk of static key compromise is low if `chmod 600` is enforced

---

## 14. Troubleshooting WireGuard

### Check if the Interface Is Up

```bash
sudo wg show
```

Expected output:
```
interface: wg0
  public key: <YOUR_PUBLIC_KEY>
  private key: (hidden)
  listening port: random

peer: <VPS_PUBLIC_KEY>
  endpoint: <VPS_IP>:51820
  allowed ips: 10.0.0.1/32
  latest handshake: 15 seconds ago    ← THIS IS KEY
  transfer: 1.24 GiB received, 89.47 MiB sent
  persistent keepalive: every 25 seconds
```

### Handshake Age Interpretation

| Handshake Age | Status | Action |
|---|---|---|
| < 3 minutes | ✅ Healthy | None |
| 3–10 minutes | ⚠ Stale | Check connectivity, try pinging 10.0.0.1 |
| > 10 minutes | ❌ Dead | Restart: `sudo systemctl restart wg-quick@wg0` |
| No handshake | ❌ Never connected | Check VPS WireGuard is running, check keys match |

### Common Issues

| Problem | Cause | Fix |
|---|---|---|
| `ping 10.0.0.1` fails | Tunnel down or VPS WireGuard not running | Restart on both sides |
| Handshake never happens | Wrong keys, wrong endpoint, or firewall blocking UDP 51820 | Verify keys match; check Oracle security list |
| Handshake succeeds but no traffic | IP forwarding disabled on VPS | `sysctl net.ipv4.ip_forward` should return `1` |
| Tunnel works initially, dies after idle | No PersistentKeepalive | Add `PersistentKeepalive = 25` to laptop config |
| `RTNETLINK answers: Operation not supported` | WireGuard kernel module not loaded | `sudo modprobe wireguard` or install `wireguard-dkms` |

### The Nuclear Fix

When in doubt:
```bash
sudo systemctl restart wg-quick@wg0
```

This tears down the wg0 interface, removes all routes, and re-creates everything from scratch. It fixes 80% of all WireGuard issues because it forces a new handshake and re-creates NAT table entries.

---

## Key Takeaways

1. **WireGuard uses UDP** — this is how it punches through CGNAT
2. **4,000 lines of code** — small enough to audit, fast enough for production
3. **Noise protocol** — one-RTT handshake with forward secrecy
4. **ChaCha20-Poly1305** — fast on any CPU, no hardware acceleration required
5. **AllowedIPs** is both a routing table and an access control list
6. **PersistentKeepalive = 25** prevents NAT table expiry — without it, the tunnel silently dies
7. **Split tunneling** (`AllowedIPs = 10.0.0.1/32`) keeps normal traffic off the VPN
8. **Keys are just Curve25519** — no certificates, no PKI, no complexity

---

*Part of Project Caktus documentation suite*
