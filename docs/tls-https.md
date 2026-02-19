# TLS/HTTPS & Certificate Deep Dive
## How Caktus Encrypts Everything in Transit

> Every byte of data between a user's browser and your apps is encrypted.
> This document explains TLS, HTTPS, certificate chains, and the ACME protocol.

---

## Table of Contents

1. [Why Encryption Matters](#1-why-encryption-matters)
2. [HTTP vs HTTPS](#2-http-vs-https)
3. [TLS: Transport Layer Security](#3-tls-transport-layer-security)
4. [The TLS 1.3 Handshake in Detail](#4-the-tls-13-handshake-in-detail)
5. [Symmetric vs Asymmetric Encryption](#5-symmetric-vs-asymmetric-encryption)
6. [Diffie-Hellman Key Exchange](#6-diffie-hellman-key-exchange)
7. [Perfect Forward Secrecy](#7-perfect-forward-secrecy)
8. [X.509 Certificates](#8-x509-certificates)
9. [Certificate Chains & Trust](#9-certificate-chains--trust)
10. [Let's Encrypt & the ACME Protocol](#10-lets-encrypt--the-acme-protocol)
11. [DNS-01 vs HTTP-01 Challenges](#11-dns-01-vs-http-01-challenges)
12. [Wildcard Certificates](#12-wildcard-certificates)
13. [How TLS Works in the Caktus Pipeline](#13-how-tls-works-in-the-caktus-pipeline)
14. [Common TLS Errors & Fixes](#14-common-tls-errors--fixes)

---

## 1. Why Encryption Matters

Without HTTPS, your data travels as plaintext. Anyone positioned between your browser and the server can:

```
Coffee Shop WiFi Attack:

You → [WiFi Router] → [ISP] → [Internet] → Server

Without HTTPS:
  WiFi operator can read:
    - Your passwords
    - Your session cookies
    - Every page you view
    - Form data you submit

With HTTPS (TLS):
  WiFi operator sees:
    - That you connected to caktus.duckdns.org
    - How much data you transferred
    - That's it. Content is encrypted.
```

This isn't theoretical — tools like Wireshark make it trivial to capture and read unencrypted HTTP traffic. Even your ISP can inspect HTTP traffic. HTTPS is not optional for any production web service.

### What TLS Provides

| Property | Meaning |
|---|---|
| **Confidentiality** | Only the intended recipient can read the data |
| **Integrity** | Data cannot be tampered with in transit |
| **Authentication** | You know you're talking to the real server (not an impersonator) |

---

## 2. HTTP vs HTTPS

```
HTTP:  Application data → TCP → IP → Network
HTTPS: Application data → TLS → TCP → IP → Network
                          ^^^
                     This is the difference
```

HTTPS is simply HTTP with TLS inserted between the application layer and TCP. The "S" stands for "Secure." The application (your web app) doesn't need to know about TLS — it sends and receives plain HTTP. The TLS layer handles encryption transparently.

### Port Convention

| Protocol | Default Port | Encrypted? |
|---|---|---|
| HTTP | 80 | ❌ No |
| HTTPS | 443 | ✅ Yes (TLS) |

VPS Caddy listens on both 80 and 443. Port 80 requests are automatically redirected to 443 (HTTPS redirect).

---

## 3. TLS: Transport Layer Security

### History

```
SSL 1.0 (1994) – Never released (security flaws)
SSL 2.0 (1995) – Deprecated (broken)
SSL 3.0 (1996) – Deprecated (POODLE attack)
TLS 1.0 (1999) – Deprecated (BEAST attack)
TLS 1.1 (2006) – Deprecated
TLS 1.2 (2008) – Still widely used
TLS 1.3 (2018) – Current standard ← Caddy uses this
```

TLS 1.3 is a major simplification over TLS 1.2:
- Removed insecure cipher suites (RC4, DES, export ciphers)
- Removed RSA key transport (no forward secrecy)
- Reduced handshake from 2-RTT to 1-RTT
- Supports 0-RTT resumption (for returning clients)

### What Changed in TLS 1.3

| TLS 1.2 | TLS 1.3 |
|---|---|
| Client proposes cipher suites, server picks | Only 5 cipher suites allowed |
| RSA key exchange allowed (no forward secrecy) | Only (EC)DHE key exchange (forward secrecy mandatory) |
| 2-RTT handshake | 1-RTT handshake |
| Many legacy options to negotiate | Clean, minimal |

---

## 4. The TLS 1.3 Handshake in Detail

When a browser connects to `https://portainer.caktus.duckdns.org`:

```
Browser                                    VPS Caddy
───────                                    ─────────

TCP 3-way handshake (SYN → SYN-ACK → ACK)
[Connection established]

──── TLS HANDSHAKE BEGINS ──────────────────────────

[1] ClientHello ──────────────────────────────────▶
    • Supported TLS versions: [1.3, 1.2]
    • Supported cipher suites:
      - TLS_CHACHA20_POLY1305_SHA256
      - TLS_AES_256_GCM_SHA384
      - TLS_AES_128_GCM_SHA256
    • Key share: client's ECDHE public key (Curve25519)
    • SNI: portainer.caktus.duckdns.org
    • Supported groups: x25519, secp256r1

◀──────────────────────────────────── [2] ServerHello
    • Selected version: TLS 1.3
    • Selected cipher: TLS_CHACHA20_POLY1305_SHA256
    • Key share: server's ECDHE public key (Curve25519)

◀──────────────────────────── [3] EncryptedExtensions
    (Encrypted from here — using handshake keys derived
     from ECDHE shared secret)

◀──────────────────────────────────── [4] Certificate
    • Server certificate: *.caktus.duckdns.org
    • Intermediate cert: Let's Encrypt R3
    • (Root CA is pre-installed in browser)

◀──────────────────────────── [5] CertificateVerify
    • Signature over handshake transcript
    • Proves server has the private key for the cert

◀──────────────────────────────────────── [6] Finished
    • MAC over entire handshake transcript
    • Proves server completed handshake correctly

[7] Finished ──────────────────────────────────────▶
    • MAC over entire handshake transcript
    • Both sides now derive the SAME session keys

════════════════════════════════════════════════════
        SESSION ESTABLISHED — ALL DATA ENCRYPTED
════════════════════════════════════════════════════

[8] Application Data ─────────────────────────────▶
    GET / HTTP/1.1
    Host: portainer.caktus.duckdns.org
    [Encrypted with session key]

◀───────────────────────────── [9] Application Data
    HTTP/1.1 200 OK
    Content-Type: text/html
    [Encrypted with session key]
```

### Key Points

- **SNI (Server Name Indication)**: The browser sends the hostname in plaintext during ClientHello. This is how the VPS knows which certificate to present. (TLS Encrypted ClientHello, or ECH, is being developed to encrypt this, but isn't widely deployed yet.)
- **1-RTT**: The entire handshake completes in one round trip. The browser sends its key share proactively in ClientHello, before knowing what the server supports.
- **Encryption starts at step 3**: Everything after ServerHello is encrypted, including the certificate.

---

## 5. Symmetric vs Asymmetric Encryption

TLS uses *both* types of encryption, for different purposes:

### Asymmetric (Public Key) Encryption

- **Key pair**: one public key, one private key
- **Encrypt**: anyone can encrypt with the public key
- **Decrypt**: only the private key holder can decrypt
- **Speed**: slow (1000× slower than symmetric)
- **Used for**: key exchange, digital signatures

| Algorithm | Type | Used In |
|---|---|---|
| RSA | Encryption + Signatures | Older TLS versions |
| ECDSA | Signatures | Certificate signatures |
| Ed25519 | Signatures | Modern certificates |
| Curve25519 (X25519) | Key exchange (ECDH) | TLS 1.3 handshake |

### Symmetric Encryption

- **One key**: same key encrypts and decrypts
- **Speed**: fast (hardware-accelerated)
- **Problem**: how do you share the key securely?
- **Used for**: bulk data encryption after handshake

| Algorithm | Type | Used In |
|---|---|---|
| AES-256-GCM | Block cipher (AEAD) | TLS 1.3 |
| ChaCha20-Poly1305 | Stream cipher (AEAD) | TLS 1.3, WireGuard |

### How TLS Combines Both

```
Phase 1: Handshake
  Use asymmetric crypto (Curve25519 ECDH) to agree on a shared secret
  Derive symmetric session keys from the shared secret

Phase 2: Data Transfer
  Use symmetric crypto (ChaCha20-Poly1305 or AES-GCM) for all data
  Fast, efficient, secure
```

This is the fundamental pattern: **asymmetric crypto to establish a shared secret, symmetric crypto for bulk data.**

---

## 6. Diffie-Hellman Key Exchange

The Diffie-Hellman (DH) protocol lets two parties agree on a shared secret over an insecure channel — without ever transmitting the secret.

### The Math (Simplified for Curve25519)

```
Setup:
  Both sides agree on a mathematical group (Curve25519 elliptic curve).

Step 1: Each side generates a random private value
  Browser: a (random, kept secret)
  Server:  b (random, kept secret)

Step 2: Each side computes a public value
  Browser: A = a × G  (scalar multiplication on the curve)
  Server:  B = b × G

Step 3: Exchange public values
  Browser sends A to server (in ClientHello key_share)
  Server sends B to browser (in ServerHello key_share)

Step 4: Each side computes the shared secret
  Browser: S = a × B = a × (b × G) = ab × G
  Server:  S = b × A = b × (a × G) = ab × G

  Both get the SAME value: ab × G

An eavesdropper who sees A and B (but not a or b) cannot compute ab × G.
This is the Elliptic Curve Discrete Logarithm Problem — computationally infeasible.
```

### Why X25519 (Curve25519)?

| Property | X25519 | RSA-2048 |
|---|---|---|
| Key size | 32 bytes | 256 bytes |
| Security level | 128-bit | 112-bit |
| Speed | Very fast | Slow |
| Forward secrecy | Yes (ephemeral keys) | No (static keys in RSA key transport) |
| Constant-time | By design | Requires careful implementation |

Curve25519 was designed by Daniel J. Bernstein to be fast, secure, and resistant to timing side-channel attacks. It's the same curve used in WireGuard's handshake.

---

## 7. Perfect Forward Secrecy

### What It Means

Even if the server's long-term private key is compromised, past TLS sessions cannot be decrypted.

### How It Works

In TLS 1.3, every session uses **ephemeral** DH key pairs:

```
Session 1: Browser generates a₁, Server generates b₁ → shared secret S₁
Session 2: Browser generates a₂, Server generates b₂ → shared secret S₂
Session 3: Browser generates a₃, Server generates b₃ → shared secret S₃
```

Each session's ephemeral keys (a, b) are destroyed after the session key is derived. If an attacker later gets the server's long-term key (used for signing the certificate), they can impersonate the server for *future* connections, but they **cannot decrypt past sessions** because the ephemeral keys no longer exist.

### Why This Matters

Imagine an attacker records all encrypted traffic between users and your Caktus server. Years later, the server's TLS private key is leaked. Without forward secrecy, the attacker could decrypt all recorded traffic. With forward secrecy, the recorded traffic remains encrypted forever.

TLS 1.3 **mandates** forward secrecy — RSA key transport (which doesn't provide it) was removed entirely.

---

## 8. X.509 Certificates

### What's in a Certificate

A TLS certificate is a digitally signed document that says: "This public key belongs to this domain."

```
X.509 Certificate for *.caktus.duckdns.org:
┌─────────────────────────────────────────────────┐
│ Version: 3                                       │
│ Serial Number: 04:a3:b2:...                     │
│ Signature Algorithm: SHA-256 with RSA            │
│                                                   │
│ Issuer: Let's Encrypt R3                         │
│   (the CA that signed this cert)                 │
│                                                   │
│ Validity:                                         │
│   Not Before: Feb 19 2026                        │
│   Not After:  May 20 2026  (90 days)             │
│                                                   │
│ Subject: CN=*.caktus.duckdns.org                 │
│                                                   │
│ Subject Alternative Names:                        │
│   DNS: *.caktus.duckdns.org                      │
│   DNS: caktus.duckdns.org                        │
│                                                   │
│ Public Key: RSA 2048-bit or ECDSA P-256          │
│                                                   │
│ Signature: [signed by Let's Encrypt R3 key]      │
└─────────────────────────────────────────────────┘
```

### The SAN Field (Subject Alternative Names)

Modern certificates use the SAN field to list all valid domains. Our cert has:
- `*.caktus.duckdns.org` — covers any subdomain
- `caktus.duckdns.org` — covers the bare domain

The wildcard `*` only covers one subdomain level: `portainer.caktus.duckdns.org` ✅ but NOT `sub.sub.caktus.duckdns.org` ❌. For Caktus, this is fine — we only use single-level subdomains.

### 90-Day Validity

Let's Encrypt certificates are valid for 90 days (not the usual 1–2 years). This is by design:
- Shorter validity limits exposure if a key is compromised
- Forces automated renewal — no forgotten cert outages
- Caddy auto-renews 30 days before expiry

---

## 9. Certificate Chains & Trust

### How Browsers Decide to Trust a Certificate

Your browser ships with ~100 pre-installed **root Certificate Authority (CA)** certificates. These are the ultimate source of trust. When Caddy presents a certificate for `*.caktus.duckdns.org`, the browser verifies a chain:

```
Trust Chain:

[1] Root CA: ISRG Root X1
    • Pre-installed in browser/OS trust store
    • Self-signed (signs its own certificate)
    • Validity: 2035-06-04
    │
    └── Signs ──▶ [2] Intermediate CA: Let's Encrypt R3
                    • Signed by ISRG Root X1
                    • Can issue end-entity certificates
                    │
                    └── Signs ──▶ [3] End Entity: *.caktus.duckdns.org
                                    • Your actual certificate
                                    • Signed by Let's Encrypt R3
                                    • This is what Caddy presents
```

The browser verifies each link:
1. Is `*.caktus.duckdns.org` signed by a valid intermediate? → Check signature
2. Is the intermediate signed by a trusted root? → Check signature
3. Is the root in my trust store? → Yes → **Chain verified** ✅

### Why Intermediates?

Root CA private keys are extremely sensitive. They're stored in hardware security modules (HSMs) in secure facilities. Using them to sign millions of certificates daily is impractical and risky.

Intermediates act as delegates: the root signs the intermediate once, then the intermediate signs end-entity certificates. If an intermediate is compromised, only certificates it signed need to be revoked — the root remains safe.

---

## 10. Let's Encrypt & the ACME Protocol

### What Is Let's Encrypt?

Let's Encrypt is a free, automated, open Certificate Authority run by the Internet Security Research Group (ISRG). It has issued billions of certificates. Before Let's Encrypt (founded 2014), certificates cost $50–300/year and required manual verification.

### What Is ACME?

**ACME (Automatic Certificate Management Environment)** is the protocol Caddy uses to communicate with Let's Encrypt. It's standardized as RFC 8555.

### ACME Flow

```
┌─────────┐                              ┌───────────────┐
│  Caddy  │                              │ Let's Encrypt │
│  (VPS)  │                              │  ACME Server  │
└────┬────┘                              └───────┬───────┘
     │                                           │
     │  1. Create account (first time only)      │
     │ ────────────────────────────────────────▶  │
     │  ◀──────── Account URL + key ────────────  │
     │                                           │
     │  2. Order cert for *.caktus.duckdns.org   │
     │ ────────────────────────────────────────▶  │
     │  ◀──── Challenge: DNS-01 ────────────────  │
     │        (create TXT record)                │
     │                                           │
     │  3. Create TXT record via DuckDNS API     │
     │ ──────▶ DuckDNS                           │
     │                                           │
     │  4. Notify: challenge is ready            │
     │ ────────────────────────────────────────▶  │
     │                                           │
     │        5. Let's Encrypt verifies TXT       │
     │        via public DNS lookup              │
     │                                           │
     │  ◀──── 6. Challenge passed ──────────────  │
     │                                           │
     │  7. Submit CSR (Certificate Signing Req)  │
     │ ────────────────────────────────────────▶  │
     │                                           │
     │  ◀──── 8. Signed certificate ────────────  │
     │                                           │
     │  9. Store cert, begin serving TLS         │
     │  10. Cleanup TXT record via DuckDNS       │
     │                                           │
     │  [30 days before expiry: repeat 2-10]     │
```

### Rate Limits

Let's Encrypt has rate limits to prevent abuse:

| Limit | Value |
|---|---|
| Certificates per domain per week | 50 |
| Duplicate certificates per week | 5 |
| Failed validations per hour | 5 |
| New registrations per IP per 3 hours | 10 |

In practice, these limits don't affect Caktus — you request one wildcard cert that covers everything. Renewal happens every 60 days (30 days before expiry), well within limits.

---

## 11. DNS-01 vs HTTP-01 Challenges

### HTTP-01 Challenge

```
Let's Encrypt: "Prove you control example.com by placing a file at:
  http://example.com/.well-known/acme-challenge/<TOKEN>"

Caddy creates the file, Let's Encrypt fetches it via HTTP.
If the file matches, you're verified.
```

**Limitation**: Only works for specific hostnames, not wildcards. You can't place a file at `http://*.example.com/...` because `*` isn't a real hostname.

### DNS-01 Challenge

```
Let's Encrypt: "Prove you control example.com by creating a TXT record:
  _acme-challenge.example.com = <TOKEN>"

Caddy calls DNS API to create the TXT record.
Let's Encrypt queries DNS and verifies.
```

**Advantage**: Proves domain-level ownership. If you can create arbitrary DNS records for `example.com`, you control the entire domain (including all subdomains).

### Why Caktus Requires DNS-01

| Requirement | HTTP-01 | DNS-01 |
|---|---|---|
| Wildcard cert | ❌ Not supported | ✅ Supported |
| Server needs port 80 open to internet | ✅ Required | ❌ Not required |
| Requires DNS provider API | ❌ No | ✅ Yes (DuckDNS) |
| Works behind CGNAT | ❌ No (can't reach your server) | ✅ Yes |

Caktus uses DNS-01 because:
1. We need a wildcard cert (one cert for all apps)
2. The VPS can do DNS-01 directly (no firewall issues)
3. DuckDNS provides a simple API for TXT record creation

---

## 12. Wildcard Certificates

### What Is a Wildcard Cert?

A wildcard certificate covers a domain and all its single-level subdomains:

```
Certificate for: *.caktus.duckdns.org + caktus.duckdns.org

Covers:
  ✅ caktus.duckdns.org
  ✅ portainer.caktus.duckdns.org
  ✅ status.caktus.duckdns.org
  ✅ hello.caktus.duckdns.org
  ✅ anything.caktus.duckdns.org
  ✅ new-app-you-add-tomorrow.caktus.duckdns.org

Does NOT cover:
  ❌ sub.sub.caktus.duckdns.org   (two levels deep)
  ❌ other.duckdns.org             (different domain)
```

### Why Wildcards Are Perfect for Caktus

Without a wildcard, adding a new app would require:
1. Request a new certificate for the subdomain
2. Wait for DNS-01 challenge to complete (minutes)
3. Risk hitting Let's Encrypt rate limits

With a wildcard:
1. Add `@myapp` matcher to Caddyfile
2. Reload Caddy
3. Done — cert already covers the new subdomain

The wildcard cert is requested once and renewed every 60 days. Adding 100 new apps doesn't trigger a single additional certificate request.

---

## 13. How TLS Works in the Caktus Pipeline

### The Encryption Journey

```
Browser                   VPS Caddy              WireGuard              Laptop Caddy
───────                   ─────────              ─────────              ────────────

[TLS 1.3 Encrypted]       Decrypt TLS
  GET /dashboard          Read Host header
  Host: portainer.....    Forward to 10.0.0.2:80
                                                 
                          [Plain HTTP]           Encrypt (ChaCha20)
                          inside WireGuard       Send encrypted UDP
                          tunnel                 to laptop
                                                 
                                                  Decrypt (ChaCha20)
                                                  [Plain HTTP]
                                                  Deliver to wg0
                                                                        Read Host header
                                                                        Route to container
                                                                        [Plain HTTP to app]
```

### Security Analysis at Each Hop

| Hop | Encrypted? | By What? | Who Can Read? |
|---|---|---|---|
| Browser → VPS | ✅ TLS 1.3 | Browser's session key | Only VPS Caddy |
| VPS Caddy internal | ⚠ Briefly plain in RAM | N/A | VPS Caddy process only |
| VPS → Laptop | ✅ WireGuard | ChaCha20-Poly1305 | Only laptop WireGuard |
| Laptop Caddy → Container | ❌ Plain HTTP | N/A | Localhost only (Docker bridge) |

The "weakest" point is the last hop: Caddy to container is unencrypted HTTP inside Docker. But this traffic never leaves the machine — it's switched inside the kernel's virtual bridge. Encrypting it would add overhead with no security benefit (if your local kernel is compromised, encryption won't help).

### Double Encryption Myth

Traffic is NOT double-encrypted at any point. The sequence is:
1. TLS encryption (browser → VPS)
2. TLS decryption at VPS Caddy
3. WireGuard encryption (VPS → laptop)
4. WireGuard decryption at laptop

Each encryption/decryption is sequential, not layered. However, an attacker would need to compromise BOTH the TLS session AND the WireGuard tunnel to see plaintext — which is effectively impossible.

---

## 14. Common TLS Errors & Fixes

### `NET::ERR_CERT_AUTHORITY_INVALID`

Browser doesn't trust the certificate.

```bash
# On VPS — check Caddy logs for cert issuance
sudo journalctl -fu caddy | grep -iE 'cert|tls|acme|duckdns'

# Common causes:
# 1. DuckDNS token is wrong → cert never issued
# 2. Caddy built without DuckDNS plugin → DNS-01 fails
# 3. Let's Encrypt rate limited → wait 1 hour
```

### `ERR_SSL_VERSION_OR_CIPHER_MISMATCH`

Client and server can't agree on a cipher suite.

```bash
# Very rare with Caddy + TLS 1.3
# Usually caused by outdated client (old browser, old curl)
# Fix: update the client, not the server
```

### `ERR_CERT_DATE_INVALID`

Certificate has expired.

```bash
# Check cert expiry
echo | openssl s_client -connect caktus.duckdns.org:443 2>/dev/null | \
  openssl x509 -noout -dates

# If expired, Caddy's auto-renewal failed
# Check Caddy logs on VPS for renewal errors
sudo journalctl -fu caddy | grep -i renew

# Force renewal attempt
sudo systemctl restart caddy
```

### `ERR_CONNECTION_REFUSED` on `:443`

TLS isn't running at all.

```bash
# On VPS
sudo systemctl status caddy     # is it running?
sudo ss -tlnp | grep 443        # is anything listening on 443?
sudo systemctl restart caddy     # restart it
```

### Certificate Transparency

All Let's Encrypt certificates are logged in public Certificate Transparency (CT) logs. This means anyone can see that `*.caktus.duckdns.org` has a certificate. This is by design — CT logs prevent CAs from issuing fraudulent certificates without detection.

You can search for your certificate at [crt.sh](https://crt.sh/?q=caktus.duckdns.org).

---

## Key Takeaways

1. **TLS 1.3** is the current standard — 1-RTT handshake, mandatory forward secrecy
2. **The handshake** uses asymmetric crypto (X25519 ECDH) to agree on a symmetric session key
3. **Certificates** prove identity — browser verifies the chain back to a trusted root CA
4. **Let's Encrypt** provides free, automated certificates via the ACME protocol
5. **DNS-01 challenge** proves domain ownership — required for wildcard certs
6. **Wildcard certs** cover all subdomains — no per-app certificate management
7. **Forward secrecy** means past sessions stay safe even if the private key leaks
8. **In Caktus, TLS and WireGuard protect different hops** — browser↔VPS (TLS), VPS↔laptop (WireGuard)

---

*Part of Project Caktus documentation suite*
