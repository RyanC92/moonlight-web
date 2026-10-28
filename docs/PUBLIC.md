# Public deployment: one owner, their own hosts

A single authenticated entry point on your own domain, streaming from hosts you
have paired with — typically **ViBeShine** on the gaming PC. Nothing is installed
beside the host; the bridge speaks the same protocol Moonlight does.

```
        your browser                     the bridge                      the host
   ┌────────────────────┐        ┌──────────────────────────┐      ┌──────────────────┐
   │  https://<domain>  │──443──▶│ Caddy (TLS)              │      │  ViBeShine       │
   │  WebRTC media      │◀─udp──▶│   └─ 127.0.0.1:8080      │      │  47984/47989 tcp │
   └────────────────────┘        │ MoonlightWeb (relay)     │──▶──▶│  47998-48010 udp │
                                 └──────────────────────────┘      └──────────────────┘
                                          RTSP / RTP / ENet, PIN pairing
```

The bridge **relays** the host's compressed stream to the browser's WebCodecs
decoder. It does not decode, re-encode, or need a GPU. The cost is one extra
network hop and roughly twice the stream bitrate in bandwidth.

This profile is for **one owner**. There are no accounts and no tenancy: the
entry point belongs to you, and every host in it is yours.

---

## 1. What you need

| Thing | Why |
|---|---|
| A box with a public IPv4 | The browser must reach the bridge's WebRTC UDP ports. A VPS is the shortest path. |
| A domain (or subdomain) | TLS is not optional: the session cookie is `Secure`, and Let's Encrypt needs a name. |
| Docker + Compose | The image and the proxy run as two containers. |
| ViBeShine on the gaming PC | The host. It must be reachable **from the bridge**, not from the browser. |

The gaming PC does **not** need to be reachable from the internet if you put the
bridge on the same LAN (see §9). For a VPS, the host needs a port forward or a
tunnel — the same requirement Moonlight has.

---

## 2. Setup

### 2.1 DNS

Point an `A` record (and `AAAA` if you have IPv6) at the box:

```
mw.example.com.  300  IN  A  203.0.113.10
```

Caddy obtains and renews the certificate itself once ports 80 and 443 reach it.
Nothing else has to be created in advance.

### 2.2 Configure

```bash
cp docker/.env.public.example docker/.env
$EDITOR docker/.env          # MW_DOMAIN=mw.example.com
```

`MW_DOMAIN` is the bare hostname — no scheme, no path. It is used twice: Caddy
serves that name, and the app trusts it (`RequestGuard::isTrustedHost`). Those
two must agree, or the app will log `Local privilege denied for untrusted Host`.

Compose reads `docker/.env` because the compose file lives in `docker/`.

### 2.3 Build the image

```bash
docker build -f docker/Dockerfile.hardened -t moonlightweb-hardened:latest .
```

### 2.4 Start

```bash
docker compose -f docker/docker-compose.public.yml up -d
docker compose -f docker/docker-compose.public.yml ps
```

Wait for both to report healthy. The first certificate issuance can take a few
seconds; `docker logs mw-caddy` shows the ACME exchange.

### 2.5 First login

The front door is a **single-use 6-digit PIN**. Ask the container for one:

```bash
docker exec moonlightweb moonlightweb --new-pin
```

Open `https://<MW_DOMAIN>`, enter the PIN, and you are in. The PIN is regenerated
the moment it is used; the session cookie (90 days, or 8 hours if you untick
"remember me") is what keeps you signed in from then on.

### 2.6 Pair the host

1. In MoonlightWeb, add a host **by IP address** — `192.168.5.200` or whatever
   address the bridge can reach. mDNS discovery will not work from a VPS.
2. MoonlightWeb shows a 4-digit PIN.
3. Open ViBeShine's own web page (`https://<host>:47990`), enter that PIN.

That is the same exchange Moonlight performs. Afterwards the pairing is stored
in the `mw-data` volume and the host appears as a card.

Streaming starts when you click it. The bridge connects to the host, receives
the encoded stream, and forwards it to the browser.

---

## 3. Ports

Public — the only three that must accept traffic from the internet:

| Port | Proto | What |
|---|---|---|
| 80 | TCP | ACME challenge and the redirect to 443 |
| 443 | TCP | the UI, the API, and the `wss://` signalling upgrade |
| 48550-48573 | UDP | WebRTC media, one port per stream slot |

Private — must **not** be reachable from outside:

| Port | Proto | What |
|---|---|---|
| 8080 | TCP | the app's HTTP listener; Caddy only |
| 8443 | TCP | the app's own self-signed HTTPS listener |
| 48001 | TCP | WebRTC signalling, proxied through 443 |
| 47984/47989/47990/48010 | TCP | ViBeShine: pairing, app list, web UI, RTSP |
| 47998-48010 | UDP | ViBeShine media |

With `ufw`, the whole policy is:

```bash
ufw default deny incoming
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 48550:48573/udp
```

Docker writes its own rules; check `ufw status` **and** `iptables -L DOCKER-USER`
after starting, because a published host-network port is not always visible to
`ufw` alone.

> **Never expose 8080.** The app treats a loopback peer carrying `Host:
> localhost` as the host machine itself, which is exactly right behind Caddy and
> exactly wrong for anyone who can reach the port directly. Caddy is the only
> thing that should be able to open it.

---

## 4. Why Caddy must share the host's network

Three behaviours in the app depend on the proxy being **loopback-local**:

1. **No redirect loop.** The app normally answers an HTTP request with `307` to
   its HTTPS port. It skips that when the peer is local *and* the Host is a
   public name, because that describes a TLS-terminating tunnel
   (`HttpServer.cpp`, "Exception 1"). A proxy reached over a bridge network
   looks remote, gets redirected to `:8443`, and the page never loads.
2. **Per-visitor rate limiting.** `AuthManager::attemptAddress` trusts
   `CF-Connecting-IP` / `X-Forwarded-For` only when the socket peer is loopback.
   From a remote proxy, every visitor shares one bucket — a single attacker can
   then lock you out.
3. **Correct privilege.** Local privilege needs *both* a loopback peer and a
   local Host name. Caddy forwards the public name, so even from loopback you
   are not silently upgraded to admin.

This is why both services use `network_mode: host` and why the compose file says
so twice.

---

## 5. Verify the deployment

Run these from somewhere that is **not** the server:

```bash
# 1. TLS and the app answer
curl -sSI https://mw.example.com/ | head -20
#    expect: HTTP/2 200, strict-transport-security, content-security-policy

# 2. The login endpoint is reachable and rate-limited
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H 'content-type: application/json' \
  -d '{"pin":"000000"}' https://mw.example.com/api/auth/validate
#    expect: 401 (not 404, not 502)

# 3. A foreign Host is refused by the proxy
curl -sk https://127.0.0.1/ -H 'Host: evil.example' -o /dev/null -w '%{http_code}\n'
#    expect: an empty response — no body, no CSP, never the app's page

# 4. The PIN survives the proxy hop and sets a Secure cookie
docker exec moonlightweb moonlightweb --new-pin     # note the PIN
curl -sS -D- -o /dev/null \
  -H 'content-type: application/json' \
  -d '{"pin":"<PIN>"}' https://mw.example.com/api/auth/validate | grep -i set-cookie
#    expect: mw_session=...; HttpOnly; Secure; SameSite=Strict
```

The last check is the important one: it proves TLS termination, the tunnel
exception, client-address handling and cookie scope all work together. If the
cookie comes back without `Secure`, you are on plain HTTP somewhere.

Then confirm the private ports are closed:

```bash
nc -zv mw.example.com 8080     # must fail
nc -zv mw.example.com 8443     # must fail
```

---

## 6. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `ERR_TOO_MANY_REDIRECTS` | Caddy is not loopback-local | use `network_mode: host` |
| Login returns `200` but you stay on the PIN screen | cookie rejected — plain HTTP | use `https://`, and check `X-Forwarded-Proto` |
| `cross_site_request_blocked` on save | proxy rewrote `Origin` or `Host` | forward both unchanged |
| `Local privilege denied for untrusted Host` in the log | `MW_DOMAIN` ≠ the Host header | make them identical |
| Stream negotiates, then drops to choppy TCP | UDP 48550-48573 blocked | open the range; do not NAT it |
| Host card shows offline | ViBeShine unreachable **from the bridge** | forward 47984/47989 to the gaming PC, or use a tunnel |
| Certificate never issues | 80/443 not reachable, or DNS not propagated | `docker logs mw-caddy` |

---

## 7. Security posture

- **The PIN is a bootstrap credential, not a password.** Six digits, single use,
  regenerated on success, three lockout tiers (30 s / 120 s / 600 s) after three
  failures, keyed per visitor address. The durable credential is the session
  cookie: `HttpOnly`, `Secure`, `SameSite=Strict`, stored server-side as a
  SHA-256 hash.
- **Admin writes need more than a session**: the remote admin password
  (PBKDF2-SHA256, 210k iterations) promotes the session, and the per-run key in
  `x-mw-admin-key` authorises the write. Reads of `/api/admin/*` are allowed to
  an authenticated session but expose no secrets.
- **The WebRTC handshake is device-bound** (`MW-BIND-v1`): the browser signs its
  half, so a relaying server cannot swap DTLS fingerprints and sit in the middle.
- **The paired host's credentials live in the `mw-data` volume.** Anyone who can
  read that volume can act as a paired client. Treat it like an SSH key: back it
  up encrypted, and revoke the pairing on the host if it leaks.

---

## 8. What this profile does not do

- **No TURN.** The app has no TURN client, so a browser behind a symmetric NAT
  may fail to establish media. On a public-IP VPS this is rarely an issue;
  behind CGNAT it will be. Port-forwarding the UDP range on the bridge's side
  helps; a TURN relay would need code.
- **No accounts.** One owner, one PIN, one session list. Multi-user is a
  different project.
- **No rendezvous.** `MW_LAN_ONLY=1` keeps the app off `moonlightweb.top`
  entirely: no introduction server, no STUN, no UPnP, no update check and no
  metrics. Your domain is the entry point.
- **The home/CGNAT variant is documented but not yet tested** end to end: bridge
  on the LAN, Caddy behind a tunnel. The app's tunnel path is the same one
  Cloudflare-style proxies use, so it should hold — but it has not been run on a
  live tunnel in this fork.

---

## 9. Running the bridge at home instead

The same compose file works on a home box if:

1. ports 80/443 are forwarded to it (or a tunnel publishes only 443), and
2. the WebRTC UDP range is forwarded one-to-one (**no NAT translation of the
   port numbers** — 48550 must arrive as 48550), or the browser is on the same
   LAN.

If neither holds, the stream falls back to its TCP/WebSocket transport: it works,
with more latency. That fallback is what the bridge compose variant documents,
and it is the honest limit of a CGNAT deployment without TURN.

---

## 10. Verified on this bench (2026-10-28)

Docker Desktop on Windows, app and proxy both `network_mode: host` (which on
Desktop means the Docker VM's namespace, so the checks ran from a container on
that same namespace). The proxy used the real `docker/Caddyfile` with one
substitution — site `mw.test:19443` and `tls internal` — because no public DNS
was available to issue a real certificate.

| Check | Result |
|---|---|
| `caddy validate` with `MW_DOMAIN` | `Valid configuration` |
| `GET /` through TLS | `200`; CSP `connect-src 'self' wss://mw.test`, HSTS, XFO, XCTO, Referrer-Policy, `X-Robots-Tag`; no `Server` header |
| Wrong PIN | `401 {"error":"invalid_pin","remaining":2}` |
| Correct PIN | `200`, `set-cookie: mw_session=…; HttpOnly; Secure; Path=/; SameSite=Strict; Max-Age=7776000` |
| Foreign `Host` | empty `200`, `content-length: 0`, no app headers |
| Spoofed `CF-Connecting-IP` (two different values) | same bucket — `remaining` went `2` → `1`, so the header is stripped before the app sees it |
| Compose interpolation | `docker compose config` valid with `MW_DOMAIN` set |

Not verified here: Let's Encrypt issuance (needs public DNS), the firewall rules
(Windows has no `ufw`), WebRTC media through a public hop, and the home/CGNAT
topology.
