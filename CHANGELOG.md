# Changelog

Changes in this repository relative to upstream
[`linckosz/moonlight-web`](https://github.com/linckosz/moonlight-web). Upstream
does not publish a changelog, so this file is the record of what this fork adds
and, just as importantly, what it does **not** change.

The upstream tree is otherwise untouched: `Dockerfile`, `docker/entrypoint.sh`,
`docker/docker-compose.yml`, `backend/` and `frontend/` keep their behaviour.

---

## [Unreleased] — hardened container deployment

### Added

**Container**

- `docker/Dockerfile.hardened` — hardened image (`moonlightweb-hardened:latest`).
  Multi-stage build on `debian:trixie` / `trixie-slim`, non-root `moonlightweb`
  user pinned to uid/gid 10001, no compilers, no `sudo`, no package manager
  state in the final image.
- `docker/docker-compose.hardened.yml` — canonical deployment. Host networking
  (required for WebRTC, mDNS, UPnP), `cap_drop: [ALL]`, `no-new-privileges`,
  `read_only` rootfs with tmpfs `/tmp` and `/run`, `shm_size: 256m`, CPU/memory/
  PID limits, bounded json-file logging, health check via `--status`.
- `docker/entrypoint-secure.sh` — entrypoint with the same operator-command
  passthrough as the upstream one, plus port validation, a `remote_admin_enabled`
  seed on first run, a security event log, and 100 MB log rotation. It
  deliberately does **not** refuse to start without a PIN (see below).
- `docker/docker-compose.testaccess.yml` — **test bench only.** A `socat` sidecar
  that publishes 18080/18443 and forwards them to the host-networked container at
  `172.17.0.1`. Needed because Docker Desktop's "host" networking is the Linux
  VM's namespace, so a browser on Windows or macOS cannot reach the container at
  `localhost`. It forwards raw TCP, adds no control, and is not part of the
  deployment. It does **not** make WebRTC media work.
- `docs/BACKLOG.md` — requested changes that are not implemented yet (ViBeShine
  download link, rebrand, removal of upstream infrastructure references), plus
  the admin-unlock finding and its fix.

**Public deployment** (one owner, their own hosts — `docs/PUBLIC.md`)

- `docker/docker-compose.public.yml` — the internet-facing profile: the hardened
  image plus **one** edge, all on host networking. `MW_DOMAIN` is passed to the
  app and to the edge. `MW_NO_TELEMETRY=1` added on top of `MW_LAN_ONLY=1`.
- **Swappable edge via compose profiles.** `COMPOSE_PROFILES` selects what faces
  the internet, and the app is identical in every case:
  `direct` starts Caddy on 80/443; `tunnel` starts `cloudflared` and opens no
  inbound port; empty starts neither, for a host-level edge (Tailscale Serve,
  nginx, Traefik). `cloudflare/cloudflared:2026.10.5` is pinned like the other
  images. Only one edge at a time — two TLS terminators for one name is a
  configuration error, not a layer.
- `docker/Caddyfile` — TLS termination for `$MW_DOMAIN`, forwarding to
  `127.0.0.1:8080`. Preserves `Host`, **replaces** `X-Forwarded-For` with the
  real peer, and deletes `CF-Connecting-IP`, `Forwarded` and `X-Real-IP`, because
  `AuthManager::attemptAddress` reads `CF-Connecting-IP` first and would otherwise
  let a visitor pick its own rate-limit bucket.
- `docker/.env.public.example` — `MW_DOMAIN`, `TZ`, `COMPOSE_PROFILES` and a
  commented `TUNNEL_TOKEN`, with the three edge modes spelled out.
- `docs/EDGE.md` — the edge contract (loopback reachability, `Host`, real client
  address, WebSocket upgrades, `MW_DOMAIN`), worked examples for Cloudflare
  Tunnel, Tailscale Serve/Funnel and nginx/Traefik, a latency/complexity
  comparison, and an honest table of what each layer does and does not protect.
- `docs/PUBLIC.md` — the deployment guide: DNS, firewall table (public 80/443 and
  UDP 48550-48573; private 8080/8443/48001 and the host's GameStream ports),
  why the proxy must be loopback-local, a verification checklist with expected
  output, failure modes, and an explicit "verified / not verified" table.

**Monitoring** (host and container metrics only)

- `docker/docker-compose.monitoring.yml` — Prometheus, Alertmanager, Grafana,
  node-exporter, cAdvisor. UIs bind to `127.0.0.1`.
- `monitoring/prometheus.yml` — scrape configuration for the three targets that
  exist. There is no application metrics job because the app has no metrics
  endpoint.
- `monitoring/rules/security.rules.yml` — host CPU/memory/disk, node-exporter
  availability, MoonlightWeb container disappearance and memory pressure.
- `monitoring/alertmanager.yml` — routing with a **placeholder receiver**; no
  webhook or API key is invented. Alerts are dropped until it is filled in.
- `monitoring/grafana/provisioning/datasources/prometheus.yml` — provisioned
  Prometheus datasource.

**Operations**

- `scripts/security-scan.sh` — inspects the running container and exits non-zero
  if a claimed control is missing. 13 pass / 0 fail / 1 expected warning (no
  capabilities added, because the ports are above 1024) once the admin password
  is set; 12/0/2 before that.
- `scripts/backup.sh` — archives the whole `/data` volume and restores it.
  Restores run as the image user, so ownership survives.
- `scripts/firewall-rules.sh` — Linux iptables **template** in a dedicated
  `MW_INPUT` chain. Dry-run by default; `--default-drop` is a separate flag.
- `scripts/MoonlightWebService.ps1` — NSSM wrapper for the Windows x64 build.
  Service lifecycle only; it does not invent configuration or download NSSM.
- Windows x64 host build path, documented in `docs/BUILD.md`: Visual Studio
  Build Tools 2022 (MSVC 14.44), Qt 6.10.3 `msvc2022_64` with WebSockets
  (`aqtinstall` route included), the bundled OpenSSL import libs, `windeployqt`,
  and the reason 6.11.x is not documented (aqt metadata 404). The build was run
  and streamed from a real ViBeShine host.

**Documentation**

- `docs/DEPLOY.md` — what is deployed, why the ports are 8080/8443, operations,
  backup/restore, reverse proxy, monitoring, troubleshooting, and an explicit
  "what this does not claim" section.
- `docs/BUILD.md` — the container build stages, arguments and verification, plus
  the Windows x64 host build (toolchain, Qt via aqt, `windeployqt`, verify) and
  base-image update procedure.
- `docs/TEST.md` — the exact verification cycle that was run, with commands and
  observed output, plus what could not be tested on this host.
- `docs/HARDENING.md` — each control, the threat it addresses, its limits, and
  the choices that were rejected.
- `CHANGELOG.md` — this file.

### Changed

- The hardened entrypoint mirrors upstream `docker/entrypoint.sh` instead of
  replacing its contract: operator commands (`--status`, `--new-pin`,
  `--set-admin-password`, `--clear-admin-password`, `--enable-internet`) `exec`
  straight through, settings are re-applied on every start, and the stale
  single-instance lock is removed.
- `remote_admin_enabled` is seeded to `false` on first run. The application's
  default is `true` (`AppSettings.cpp`); a hardened deployment should not let
  another machine unlock the admin page until the operator asks for it.
  `--set-admin-password` deliberately re-enables it.
- Listener defaults moved to 8080/8443 in the hardened image. Binding 80/443 as
  a non-root process is not reliable; see "Rejected" below.
- The application user's uid/gid are pinned to `10001:10001`. `useradd -r`
  allocated 997:996 in the first build and 999:999 after removing two packages,
  which left the rebuilt image unable to write its own volume. Rebuilds now
  keep ownership; `scripts/backup.sh --restore` also chowns the restored tree.
- `docker/README.md` gained a pointer to the hardened variant at the top. The
  upstream instructions below it are unchanged and still describe the official
  image.
- `README.md`'s Docker section points at the hardened variant and its docs. The
  upstream quick-start remains as-is.

- `docs/DEPLOY.md` §6.1 explains the admin page behind a reverse proxy: the
  local-privilege test needs a local peer **and** a local `Host`, so the password
  prompt is the correct behaviour there, and rewriting `Host` to a loopback name
  would hand out admin without a password.

- `docs/DEPLOY.md` §6 now points at the public profile and proxies to the app's
  plain-HTTP listener on `8080` instead of double-terminating TLS through `8443`.
  The nginx example gained `CF-Connecting-IP` / `Forwarded` clearing and
  `X-Forwarded-For $remote_addr` (replace, not append): with `$proxy_add_x_forwarded_for`
  plus a pass-through `CF-Connecting-IP`, a client could choose its own
  rate-limit key.

- **`MW_DOMAIN` is now written into `settings.json` on every start.** The variable
  is only a base for the retired `<uid>.<domain>` name; the served name comes from
  `AppSettings::domain()`, which reads the `domain` key and returns empty without
  it. The entrypoint lowercases and validates the value (bare FQDN only, no
  scheme, no leading/trailing dot) and applies it like the listener ports, so
  changing the name in `docker/.env` takes effect on the next `up -d` rather than
  needing a fresh volume. `docs/EDGE.md` and `docs/PUBLIC.md` now state this
  instead of implying the variable alone is sufficient.

### Fixed

- **Two defects found by running a live tunnel, not by reading the code.**
  1. A container started with `MW_DOMAIN` set still logged
     `Local privilege denied for untrusted Host '<name>' (possible DNS
     rebinding)` for *every* request: the variable never reached
     `AppSettings::domain()`. Fixed in `docker/entrypoint-secure.sh` as described
     under "Changed".
  2. `AuthManager::attemptAddress` reads `CF-Connecting-IP` **before**
     `X-Forwarded-For` and `Forwarded`. A visitor could send their own
     `CF-Connecting-IP` through a proxy that merely appended to `X-Forwarded-For`
     and pick a fresh rate-limit bucket per attempt, defeating the PIN lockout.
     `docker/Caddyfile` now deletes `CF-Connecting-IP`, `Forwarded` and
     `X-Real-IP` and replaces `X-Forwarded-For` with the real peer;
     `docs/DEPLOY.md` §6 gives the nginx equivalent.

- **The admin page could not be unlocked from a remote browser.**
  `AdminView._isLocalhost()` fell back to `window.location.hostname`, so any
  client that reached the app under the name `localhost` — a TLS-terminating
  reverse proxy, a tunnel, or the test bench — was treated as the host machine
  and shown the full admin page, while the server correctly refused every write.
  The page looked editable and every save returned 403. The verdict from
  `/api/auth/status` is now authoritative once it has answered; the URL fallback
  only covers the moment before that answer arrives. The password prompt the
  page was always meant to show now appears, and a save after unlocking
  persists.
- **Misleading `403` text.** `SystemRoutes.cpp` answered "can only be modified
  from localhost" when the actual requirement was the remote admin password.
  All four occurrences now name the real condition.
- **`README.md` overstated the admin guard.** It claimed every `/api/admin/*`
  request gets 403. Authenticated reads return 200 by design, so the page can
  load the prompt that unlocks it; only changes are gated.

- **`scripts/MoonlightWebService.ps1` set two environment variables the binary
  never reads.** `MW_HTTP_PORT`/`MW_HTTPS_PORT` are a container-entrypoint
  convention: the entrypoint translates them into `settings.json`. The
  executable honours only `--port` (HTTP); the HTTPS port comes from
  `settings.json` and falls back from 443 through 8443/18443. The service now
  passes `--port`, sets only `MW_SERVICE` (and `MW_LAN_ONLY` when asked), and
  reports whichever sockets the process actually holds instead of assuming a
  fixed pair.

### Removed

- `SECURITY_FIXES_SUMMARY.md` and `SECURITY_HARDENING_CHECKLIST.md` — contained
  claims that were not true of this codebase (system-command-injection fixes,
  a score, mandatory-auth startup enforcement).
- `docs/DEPLOYMENT_GUIDE.md` — duplicate of a deployment guide with the same
  inaccuracies.
- `docker/security-config.json` — nothing parses it; the app reads
  `settings.json`.
- `docker/logrotate.conf` — no logrotate daemon runs in the container; the
  entrypoint rotates oversized logs itself.
- `profiles/seccomp.json` — never wired into the compose file, never validated
  against Qt/WebRTC. Docker's default profile applies instead.
- `frontend/nginx-secure.conf` — invalid nginx syntax (a `server` block nested
  inside another `server`), and it served static files rather than proxying the
  app.
- `scripts/setup-hardened.sh` — wrote a fictional `.env`, a systemd unit that
  ran as root, and an entrypoint that did nothing.
- `docker/data/mw-data/` — stale state from an earlier bind-mount iteration.

### Security posture actually implemented

| Control | Where | Evidence |
|---|---|---|
| Non-root process | image `USER` | `id` → `uid=10001(moonlightweb)` |
| All capabilities dropped | compose `cap_drop` | `CapDrop=["ALL"]`, `CapAdd=null` |
| No privilege escalation | compose `security_opt` | `no-new-privileges:true` |
| Read-only root filesystem | compose `read_only` + tmpfs | `ReadonlyRootfs=true` |
| Resource bounds | compose | `Memory=2 GiB`, `NanoCpus=2.0`, `PidsLimit=512` |
| Internet Access refused | `MW_LAN_ONLY=1` (read by `Edition.cpp`) | startup log line |
| Admin unlock off by default | `remote_admin_enabled=false` seed | `settings.json` |
| Security headers | emitted by the app | `curl -I` shows CSP, HSTS, XFO, XCTO, Referrer-Policy |
| Auth | PIN (in-memory, single-use) + PBKDF2-SHA256 admin password | both exercised |
| Security event log | entrypoint → `security.log` | file written at boot |

### Not included, and why

- **No seccomp profile.** A hand-written allowlist that has not been run against
  Qt, WebRTC and the native host is more likely to break media than to stop an
  attack.
- **No mandatory-auth startup gate.** The PIN lives in the running server's
  memory and is single-use; there is no persisted PIN to check. An entrypoint
  that refuses to start without one creates an unfixable deadlock — the
  container the operator would run `--new-pin` against never starts.
- **No `TLS 1.3 only`.** The server uses OpenSSL from the Debian base; the
  minimum protocol version is not asserted by this configuration.
- **No rate-limit environment variables.** Limits are compiled into
  `ConnectionGuard` (200 connections per window per IP) and `AuthManager`.
  `MW_MAX_CONNECTIONS_PER_IP`, `MW_RATE_LIMIT_PER_MINUTE` and similar names are
  not read by the code and have been removed from the environment.
- **No application metrics endpoint.** `/metrics` returns the SPA index. The
  monitoring stack covers the host and containers, not app internals.
- **No `NET_BIND_SERVICE`.** The image binds above 1024, so no capability is
  needed. On a host where 80/443 are required, terminate them in a reverse
  proxy.

### Verified on

- Docker 29.9.2 / Docker Compose v5.6.1, Windows host with Docker Desktop
  (Linux containers). Container checks were run inside the container because
  Docker Desktop's host networking belongs to the VM, not to Windows.
- Image build, container start, health check, HTTP/HTTPS responses, both auth
  flows, security scan, backup, restore, and the monitoring stack's three
  Prometheus targets.
- Public profile: `caddy validate` against the shipped Caddyfile, `docker compose
  config` with `MW_DOMAIN` set, and a TLS-terminated path in front of the app —
  200 with the app's security headers, PIN login through the proxy (wrong PIN
  401, right PIN 200 with `Secure; HttpOnly; SameSite=Strict`), a foreign `Host`
  refused without reaching the app, and two different spoofed
  `CF-Connecting-IP` values landing in the same rate-limit bucket.
- Swappable edge: `docker compose config --services` resolves to
  `moonlightweb + caddy`, `moonlightweb + cloudflared`, or `moonlightweb` alone
  for the three `COMPOSE_PROFILES` values.
- **Cloudflare Tunnel, end to end.** A live quick tunnel
  (`cloudflared tunnel --url http://127.0.0.1:8080`) against the app, reached from
  the Windows host over the public internet: `200` for `/` with `connect-src`
  scoped to the tunnel hostname, wrong PIN `401 remaining: 2`, correct PIN `200`
  with a `Secure; HttpOnly; SameSite=Strict` cookie, the same PIN refused on
  reuse, and no `untrusted Host` warnings after the entrypoint began writing
  `domain`. The two defects listed under "Fixed" were found by this run.
- `MW_DOMAIN` handling in the entrypoint: `sh -n` clean, and the applied value
  appears in `settings.json` as `domain` after `up -d`.
- The public visitor surface, with the app reached from a non-loopback peer under
  its trusted name: `/api/hosts` `401`, `/api/admin/token` `403`, `/api/health`
  and `/api/server/hostname` `200`; with a PIN session, `/api/admin/token`
  answers `{}` and an admin write is `403`. Three consecutive wrong PINs produce
  the 30 s lockout (`429 rate_limited` even for the correct PIN), and it clears.
  Procedure and expected output in `docs/TEST.md` §6.4.

### Not verified

- `scripts/firewall-rules.sh` against live iptables (Windows test host).
- `scripts/MoonlightWebService.ps1` `install`/`uninstall` (needs elevation and
  NSSM). `status` and `help` were executed.
- Let's Encrypt issuance here — it needs public DNS, which this bench does not
  have. Caddy's configuration was validated, and TLS was exercised with its
  internal CA instead.
- A **named** Cloudflare tunnel with a token (`COMPOSE_PROFILES=tunnel`): the
  quick tunnel exercises the same transport and header path, but the token flow
  itself was not run.
- Tailscale Serve/Funnel, and nginx/Traefik as edges.
- WebRTC media through any public hop. The TCP fallback cannot be exercised
  across the Docker Desktop VM boundary, so the stream was verified on the
  Windows build instead.
