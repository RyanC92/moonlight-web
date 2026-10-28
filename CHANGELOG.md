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

**Documentation**

- `docs/DEPLOY.md` — what is deployed, why the ports are 8080/8443, operations,
  backup/restore, reverse proxy, monitoring, troubleshooting, and an explicit
  "what this does not claim" section.
- `docs/BUILD.md` — build stages, arguments, verification, base-image updates.
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

### Not verified

- `scripts/firewall-rules.sh` against live iptables (Windows test host).
- `scripts/MoonlightWebService.ps1` `install`/`uninstall` (no NSSM, no Windows
  build of the app on the test host). `status` and `help` were executed.
- The Windows x64 build itself: no MSVC/Qt toolchain on the test machine.
