# Deploying the hardened MoonlightWeb image

This is the canonical deployment guide for `docker/Dockerfile.hardened` and
`docker/docker-compose.hardened.yml`. Everything here was exercised against the
built image; anything not exercised is called out as such.

- Image: `moonlightweb-hardened:latest`
- Verified on: Docker 29.9.2, Docker Compose v5.6.1, Debian trixie base
- Network layout: **host networking** (recommended for WebRTC, mDNS and UPnP)

---

## 1. What you get

| Control | How it is implemented | Verified |
|---|---|---|
| Non-root process | `USER moonlightweb` in the image | `id` → `uid=10001(moonlightweb)` |
| No capabilities | `cap_drop: [ALL]`, no `cap_add` | `CapDrop=["ALL"]`, `CapAdd=null` |
| No privilege escalation | `no-new-privileges:true` | `SecurityOpt` contains it |
| Read-only root filesystem | `read_only: true` + tmpfs `/tmp`, `/run` | `ReadonlyRootfs=true` |
| Resource bounds | `cpus: 2.0`, `mem_limit: 2g`, `pids_limit: 512` | `docker inspect` values |
| Internet Access refused by the app | `MW_LAN_ONLY=1` (runtime setting in `Edition.cpp`) | startup log line |
| Non-default listener ports | 8080 / 8443, above 1024 | `--status` output |
| Admin unlock off by default | `remote_admin_enabled=false` seeded on first run | `settings.json` |
| Auth | PIN (`--new-pin`, single-use, in memory) + admin password (PBKDF2-SHA256) | both exercised |
| Security headers | emitted by the app itself | `curl -I` shows CSP/HSTS/XFO/XCTO/Referrer-Policy |
| Security event log | `/data/.local/share/MoonlightWeb/MoonlightWeb/security.log` | file written at boot |
| Health check | `moonlightweb --status` | container reports `(healthy)` |

### What this image does *not* claim

- **No application metric endpoint.** `/metrics` returns the SPA index. The
  monitoring stack in `docker/docker-compose.monitoring.yml` therefore covers
  the host and containers, not app internals.
- **No custom seccomp profile.** Docker's built-in default seccomp profile
  applies. An unvetted hand-written allowlist is more likely to break the app
  than to add security, so none is shipped.
- **No TLS 1.3-only setting.** The server uses OpenSSL 3.5.7 and serves TLS with
  a self-signed certificate; the minimum protocol version is not asserted here.
- **No rate-limit env variables.** Connection and auth limits are compiled into
  the app (`ConnectionGuard`, `AuthManager`). There is no supported knob.
- **No automatic PIN.** The PIN is issued into the running server's memory, one
  per device. The container cannot invent one for you.

---

## 2. Build

```bash
git clone https://github.com/RyanC92/moonlight-web.git
cd moonlight-web
docker build -f docker/Dockerfile.hardened -t moonlightweb-hardened:latest .
```

Takes ~3 minutes cold on a modern machine. `docker image ls` should show
601 MB on disk on the test build.

---

## 3. Run

```bash
docker compose -f docker/docker-compose.hardened.yml up -d
docker compose -f docker/docker-compose.hardened.yml ps
```

Expected:

```
NAME           IMAGE                          STATUS
moonlightweb   moonlightweb-hardened:latest   Up (healthy)
```

The entrypoint prints a banner with the setup commands still to run.

### 3.1 Open the admin page

```bash
docker exec -it moonlightweb moonlightweb --set-admin-password
docker exec moonlightweb moonlightweb --new-pin
docker exec moonlightweb moonlightweb --status
```

- `--set-admin-password` reads the password from stdin; when piped it does not
  ask for confirmation:
  `printf 'a-long-password\n' | docker exec -i moonlightweb moonlightweb --set-admin-password`
- `--new-pin` prints a six-digit PIN. It is **single-use**: run it again for
  each device.
- `--status` prints the URL, e.g. `https://<host>:8443`.

Open that URL and accept the self-signed certificate.

### 3.2 Why ports 8080/8443 and not 80/443

The container is non-root. Binding 80/443 as non-root needs either:

- `NET_BIND_SERVICE` delivered to a non-root process, which Docker does not do
  reliably across hosts (observed here: the server logged
  `HTTP port 80 unavailable (The address is protected)` and fell back to
  8443), or
- a file capability, which `no-new-privileges` deliberately disables, or
- `net.ipv4.ip_unprivileged_port_start=0`, which Docker refuses with
  `sysctl ... not allowed in host network namespace`.

So the hardened image uses 8080/8443. To serve 443, put a reverse proxy in
front (§6) — which also gives you a real certificate.

### 3.3 Changing ports

Edit the compose file:

```yaml
environment:
  MW_HTTP_PORT: "9080"
  MW_HTTPS_PORT: "9443"
```

Both are validated by the entrypoint before being written to `settings.json`; an
invalid value aborts startup with a clear error rather than binding something
unexpected.

These two variables are a **container convention, not a binary feature**: the
entrypoint translates them into `settings.json` keys `http_port`/`https_port`.
The executable itself reads neither — outside the container, set ports with
`--port` (HTTP) or the Admin page (HTTPS). See `scripts/MoonlightWebService.ps1`
for the Windows service equivalent.

### 3.4 Stable uid (why rebuilds keep the volume)

The application user is pinned to **uid/gid 10001**, not allocated with
`useradd -r`. The allocator picks the next free id, so adding or removing a
package that ships a system user changes it silently — observed here: 997:996
before removing two packages, 999:999 after. A rebuild would then no longer own
its own `/data` volume and the container would fail with
`cannot create .../settings.json: Permission denied`.

If you used an image built **before** the uid was pinned, fix the volume once:

```bash
docker compose -f docker/docker-compose.hardened.yml down
docker run --rm --user 0 -v docker_mw-data:/data \
  --entrypoint sh moonlightweb-hardened:latest \
  -c 'chown -R moonlightweb:moonlightweb /data'
docker compose -f docker/docker-compose.hardened.yml up -d
```

`scripts/backup.sh --restore` does the same chown itself, so a restore repairs
ownership regardless of which image wrote the archive.

---

## 4. Operations

```bash
# logs
docker compose -f docker/docker-compose.hardened.yml logs -f

# security events
docker exec moonlightweb cat /data/.local/share/MoonlightWeb/MoonlightWeb/security.log

# live resource use
docker stats moonlightweb --no-stream

# restart
docker compose -f docker/docker-compose.hardened.yml restart

# stop (keeps the volume)
docker compose -f docker/docker-compose.hardened.yml down

# stop and delete all state
docker compose -f docker/docker-compose.hardened.yml down -v
```

### 4.1 Back up and restore

```bash
./scripts/backup.sh                 # writes backups/moonlightweb-<timestamp>.tar.gz
./scripts/backup.sh --list
./scripts/backup.sh --restore backups/moonlightweb-<YYYYmmdd_HHMMSS>.tar.gz
```

Both paths are exercised by `docs/TEST.md`. A restore stops the container,
extracts into the volume through a short-lived root helper, then
`chown -R moonlightweb:moonlightweb` — so an archive written by an image with a
different uid still restores correctly.

### 4.2 Security scan

```bash
# On a Linux host with the docker CLI:
./scripts/security-scan.sh moonlightweb

# Or, from any host that can talk to the Docker socket:
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/scripts:/scripts:ro" \
  docker:cli sh /scripts/security-scan.sh moonlightweb
```

Exit code 0 means no failed check. Warnings are expected where they describe a
deliberate choice (e.g. no capabilities added because ports are >1024).

---

## 5. Firewall

The container uses host networking, so filter on the host. `scripts/firewall-rules.sh`
is an **iptables template for Linux**; review it before running and adjust the
SSH port/interface. It is not exercised by the test cycle (the test host is
Windows).

Ports to account for:

| Port | Proto | Purpose |
|---|---|---|
| 8443 | TCP | web UI + signalling |
| 8080 | TCP | plain HTTP listener |
| 47999 | UDP | Internet Access UPnP mapping |
| 48550–48573 | UDP | WebRTC media, one per stream slot |
| 3478 | UDP | STUN, only if you use one |
| 5353 | UDP | mDNS discovery (LAN only) |

If you enable Internet Access (`MW_LAN_ONLY` unset and `--enable-internet`), the
relay handles reachability and you should not open these to the Internet
wholesale.

---

## 6. Reverse proxy for 443 (recommended)

For anything reachable from the internet, use the prepared profile instead of
hand-rolling a proxy — it ships the Caddyfile, the firewall list and the
verification steps:

```bash
docker compose -f docker/docker-compose.public.yml up -d
```

See **`docs/PUBLIC.md`**. In short: Caddy terminates TLS for `MW_DOMAIN` and
forwards to the app's **HTTP** listener on `127.0.0.1:8080`, and must share the
host's network namespace so the app sees a loopback peer. That is what makes the
app's tunnel path (`HttpServer.cpp`, "Exception 1") and its per-visitor rate
limiting work.

If you only need 443 on a trusted LAN, the minimal Caddy block is:

```caddyfile
moonlight.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Proxy to `8080` (plain HTTP), not `8443`: the HTTPS listener exists for direct
LAN access with a self-signed certificate, and double-terminating TLS through it
buys nothing.

nginx equivalent. The two `CF-Connecting-IP` / `Forwarded` lines are not
cosmetic — `AuthManager::attemptAddress` reads `CF-Connecting-IP` **before**
`X-Forwarded-For`, so if nginx passes a client-supplied one through, the visitor
chooses its own rate-limit bucket:

```nginx
server {
    listen 443 ssl;
    server_name moonlight.example.com;

    ssl_certificate     /etc/letsencrypt/live/moonlight.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/moonlight.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        # Replace, do not append, and drop the headers the app trusts first.
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header CF-Connecting-IP "";
        proxy_set_header Forwarded "";
        proxy_read_timeout 3600s;
    }
}
```

WebSocket upgrade headers matter: the signalling channel upgrades. Do not
duplicate the app's own security headers (CSP, HSTS, X-Frame-Options,
X-Content-Type-Options, Referrer-Policy) — it emits them, and two sources of
truth drift.

### 6.1 Admin page through a proxy

Through a proxy every visitor's TCP peer is loopback, so the "am I the host
machine?" test needs a second condition, and the code has one
(`RequestGuard.cpp:278`):

```cpp
d.localPrivilege = ctx.peerLocal && isLocalHostName(hostHeader);
```

A request is treated as coming from the host only when the peer is one of this
machine's own addresses **and** the `Host` header names a local host
(`localhost`, `127.0.0.1`, `::1`, or a private/loopback IP literal —
`RequestGuard.cpp:143`). Under `https://moonlight.example.com` the second
condition is false, so the Admin page shows its **password unlock** prompt. That
is correct, not a fault. A reverse proxy does not and must not turn the admin
page into a local one.

Because `Host` carries that weight, one proxy mistake is worth naming: **never
rewrite `Host` to a loopback name.** `proxy_set_header Host 127.0.0.1:8443;`
(a common shortcut when an upstream complains about the hostname) would make
every proxied visitor pass `isLocalHostName` and hand out the admin page with no
password. Pass the browser's `Host` through, as both examples above do.

`X-Forwarded-For` is not trusted for the local decision either: the client
address is taken from `cf-connecting-ip`, else the last `X-Forwarded-For` entry,
else `Forwarded` (`AuthManager.cpp:397`), so a remote client stays remote even
though the socket came from loopback. Keep those headers set by the edge only —
Caddy and nginx both overwrite a client-supplied value, which is what the
application expects.

Consequences worth knowing:

- Set the admin password before relying on the proxy:
  `docker exec -i moonlightweb moonlightweb --set-admin-password`.
- Keep `Host` and `X-Forwarded-Proto` as in the examples; the page derives links
  from them.

---

## 7. Monitoring (host and containers)

```bash
docker compose -f docker/docker-compose.monitoring.yml up -d
docker compose -f docker/docker-compose.monitoring.yml ps
```

- Grafana `http://localhost:3000` (admin/admin on first login; change it)
- Prometheus `http://localhost:9090`
- Alertmanager `http://localhost:9093`

All UIs bind to `127.0.0.1`. Alert delivery is **not** configured: the receiver
in `monitoring/alertmanager.yml` is a placeholder and alerts are dropped until
you fill it in.

Alert rules cover host CPU/memory/disk, node-exporter availability, the
MoonlightWeb container disappearing from cAdvisor, and its memory approaching
the limit. They do not cover login failures or certificate expiry, because the
metrics for those do not exist.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Container restarts in a loop | A previous revision of this image refused to start without a PIN. The current entrypoint does not. | Rebuild: `docker build -f docker/Dockerfile.hardened -t moonlightweb-hardened:latest .` |
| `HTTP port 80 unavailable` in logs | Non-root cannot bind <1024 | Use 8080/8443 (default) or front with a proxy |
| `https://localhost:8443` unreachable from the Windows host | Docker Desktop's host networking is the VM's, not Windows' | Test from inside: `docker exec moonlightweb curl -k -I https://localhost:8443/`; deploy on Linux for real host networking |
| `--status` says no PIN | PINs are in-memory and single-use | `docker exec moonlightweb moonlightweb --new-pin` |
| Settings look wrong after first boot | The server rewrites `settings.json` with the defaults it actually bound | Check `docker logs`; the entrypoint re-applies the ports each start |
| `sysctl ... not allowed in host network namespace` | `ip_unprivileged_port_start` cannot be namespaced off the host network | Do not set it; use high ports |
| `cannot create .../settings.json: Permission denied` after a rebuild | the image's uid changed and no longer owns `/data` | pin is now 10001; run the one-time `chown` in §3.4 |

---

## 9. Upgrading

```bash
git pull
docker build -f docker/Dockerfile.hardened -t moonlightweb-hardened:latest .
docker compose -f docker/docker-compose.hardened.yml up -d --force-recreate
```

The data volume is untouched. Note that a rebuild also picks up a newer
`debian:trixie-slim`, which is how base-image security updates arrive.
