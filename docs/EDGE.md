# Layering an edge (optional)

The app never has to be the thing that faces the internet. It needs **one**
component in front of it, and you can swap that component without touching the
app, the image, or your data.

`docker/docker-compose.public.yml` ships two edges and leaves room for a third:

| `COMPOSE_PROFILES` | Edge | Inbound ports | TLS by |
|---|---|---|---|
| `direct` | Caddy (bundled) | 80, 443 TCP + 48550-48573 UDP | Let's Encrypt, automatic |
| `tunnel` | cloudflared (bundled) | **none** | Cloudflare |
| *(empty)* | whatever you run on the host | whatever it uses | Tailscale, nginx, Traefik, … |

Set it in `docker/.env`, then `docker compose -f docker/docker-compose.public.yml up -d`.

---

## The contract

Every edge must do these four things. They are not preferences; each one maps to
a behaviour in the app.

| Requirement | Why | How |
|---|---|---|
| Reach the app at **`127.0.0.1:8080`** | The app skips its HTTP→HTTPS redirect for a loopback peer with a public `Host` (its "TLS-terminating tunnel" case), and only trusts forwarded client addresses from loopback | share the host network namespace, or terminate on the host itself |
| Present **`Host: <MW_DOMAIN>`** | `RequestGuard::isTrustedHost` compares it with the stored domain; a mismatch is logged as a possible DNS-rebinding attempt | preserve the incoming `Host`, do not rewrite it |
| Send the **real client address** | `AuthManager` rate-limits per visitor; behind a proxy every request would otherwise share one bucket | replace `X-Forwarded-For`; delete `CF-Connecting-IP` and `Forwarded` — the app reads those *first* |
| Carry **WebSocket upgrades** | `/ws` is the WebRTC signalling channel | most edges do this automatically; nginx needs `Upgrade`/`Connection` |

One more, outside the proxy: **`MW_DOMAIN` must equal the public hostname.** The
entrypoint writes it into `settings.json` as `domain` on every start — that key
is what the server actually trusts, and without it you will see
`Local privilege denied for untrusted Host` in the log for every request.

---

## Choosing

| Your situation | Use | Media path |
|---|---|---|
| Public IP, want the lowest latency | `direct` | UDP 48550-48573 straight to the browser |
| CGNAT, dynamic IP, or you want the origin hidden | `tunnel` | falls back to TCP/WebSocket through the edge |
| Private access only, no public exposure | Tailscale, `COMPOSE_PROFILES=` | UDP over the tailnet |
| Already run nginx/Traefik for other services | point it at `127.0.0.1:8080` | UDP if you forward the range |

Only one edge at a time. Caddy **and** a tunnel would mean two TLS terminators,
two certificates fighting over the same name, and a media path that has to
survive both.

---

## Cloudflare Tunnel

No inbound port. `cloudflared` dials out, Cloudflare serves the name, and your
home IP stays unpublished.

1. Zero Trust → **Networks → Tunnels → Create a tunnel**. Copy the token.
2. In the tunnel, add a **public hostname**: your domain, service
   `http://localhost:8080`. That is the whole routing rule — no path, no TLS
   options.
3. `docker/.env`:
   ```ini
   MW_DOMAIN=mw.example.com
   COMPOSE_PROFILES=tunnel
   TUNNEL_TOKEN=eyJhIjoi...
   ```
4. `docker compose -f docker/docker-compose.public.yml up -d`
5. Confirm nothing is listening publicly:
   ```bash
   ss -lntu | grep -E ':(80|443|8080|8443)\b'   # expect no output
   ```

**The media caveat.** Cloudflare Tunnel carries HTTP and WebSocket, not UDP.
The stream falls back to its TCP/WebSocket transport: playable, noticeably
higher latency, and the media crosses Cloudflare's network. If latency matters
more than hiding the origin, use `direct` and forward UDP 48550-48573.

**Optional second gate.** Cloudflare Access can put SSO (Google, GitHub, OTP) in
front of the hostname, so an unauthenticated visitor never reaches the PIN wall.
It is independent of the app and does not change anything in this repository.
It protects the web UI path; it is not a substitute for the app's own auth.

---

## Tailscale

Tailscale gives you a private network instead of a public endpoint. It is the
one option here that keeps **UDP media working without any port forwarding**,
because the tailnet is a real interface, so the app's WebRTC ports are reachable
directly by other tailnet devices.

### Private (tailnet only)

1. Install Tailscale **on the host**, not in a container: `tailscale up`.
2. Leave `COMPOSE_PROFILES=` empty in `docker/.env`, so compose starts the app
   and nothing else.
3. Give it a TLS name (browsers refuse `Secure` cookies over plain HTTP, and the
   app always sets `Secure`):
   ```bash
   tailscale cert "$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')"
   tailscale serve --bg --https=443 http://127.0.0.1:8080
   ```
   Enable **HTTPS Certificates** and **MagicDNS** in the tailnet admin console
   first.
4. `MW_DOMAIN=<machine>.<tailnet>.ts.net` in `docker/.env` — the exact name
   `tailscale serve` publishes.
5. Browse to `https://<machine>.<tailnet>.ts.net` from any device on the tailnet.

`tailscale serve` connects from `127.0.0.1`, so the loopback contract holds and
the app behaves exactly as it does behind Caddy.

### Public (Funnel)

```bash
tailscale funnel --bg --https=443 http://127.0.0.1:8080
```

Same name, reachable from the internet through Tailscale's edge. Like
Cloudflare, Funnel is HTTP-only, so media falls back to TCP/WebSocket.

### Access control

Tailscale ACLs decide **who can reach the port at all** — a network-level gate
that sits before the PIN. That is a meaningful second factor for a private
deployment, and it costs nothing to add.

---

## nginx, Traefik, or anything else

The rules are the contract at the top of this page. For nginx specifically,
`docs/DEPLOY.md` §6 has a complete server block, including the two header lines
that are easy to miss:

```nginx
proxy_set_header X-Forwarded-For $remote_addr;   # replace, do not append
proxy_set_header CF-Connecting-IP "";            # the app trusts this first
proxy_set_header Forwarded "";
```

Traefik's equivalents are `forwardedHeaders.insecure=false` with a trusted-IP
list — or, simpler, let Traefik write `X-Forwarded-For` and add a middleware
that removes `CF-Connecting-IP`.

---

## What each layer does and does not protect

| Layer | Stops | Does not stop |
|---|---|---|
| Firewall / no inbound port | direct scans of 8080, 8443, GameStream ports | anything through the edge you chose |
| Tailscale ACL | devices that are not on your tailnet | a compromised tailnet device |
| Cloudflare Access | unauthenticated visitors reaching the app | Cloudflare itself reading HTTP traffic |
| App PIN + session | unauthorised use of the app | someone holding a valid session cookie |
| Admin password | changing settings from a session | — |

Be clear-eyed about the tunnel case: **Cloudflare terminates TLS**, so it can
see the web UI traffic (including your PIN entry) in plaintext at its edge, and
the TCP media fallback passes through it too. That is the price of hiding your
origin. Tailscale does not have that property — it is WireGuard end to end, and
your own devices are the only endpoints.

None of this changes the app's own model: one owner, one single-use PIN, a
90-day session cookie, and an admin password for writes.

---

## Verified

- **Cloudflare Tunnel, end to end**: a live quick tunnel to `127.0.0.1:8080`
  returned the app's page (`200`), the CSP correctly scoped to the tunnel's
  hostname, and a PIN login through it set `Secure; HttpOnly; SameSite=Strict`.
  The PIN was refused on second use.
- **`MW_DOMAIN` handling**: without the entrypoint writing `domain` into
  `settings.json`, every request through the tunnel was logged as
  `Local privilege denied for untrusted Host`. With it, the log is clean.
- **Profiles**: `docker compose config --services` resolves to
  `moonlightweb + caddy`, `moonlightweb + cloudflared`, or `moonlightweb` alone.

Not verified here: a named Cloudflare tunnel with a token (the quick tunnel
exercises the same transport), Tailscale Serve/Funnel, and media over either
tunnel — the fallback is the app's existing TCP transport, which this bench
cannot exercise across the Docker Desktop VM boundary.
