# Hardening notes

What was hardened, against what, and where the limits are. This file exists so
that nobody has to guess whether a control is real, decorative, or absent. Every
"verified" line was produced by the commands in `docs/TEST.md`.

---

## 1. Threat model

The deployment this targets is a **LAN service**: MoonlightWeb on a home or
office network, reached by browsers on the same network, streaming from a
Sunshine/GameStream host. The assets worth protecting are:

1. **The host** — the container shares its network namespace and its kernel.
2. **The pairing identity** — `settings.json` holds the HMAC key, the host
   signing key and the admin password hash; `cert/key.pem` holds the TLS key.
   Anyone with that volume can impersonate this server.
3. **Availability** — a stream server that can be made to exhaust the host is a
   denial of service against the desktop it is meant to serve.

Out of scope: a multi-tenant cluster, hostile co-tenants on the same Docker
daemon, and physical access. Those need controls this repository does not
provide.

---

## 2. Controls

| # | Control | Implementation | Verified |
|---|---|---|---|
| 1 | Non-root process | `USER moonlightweb` | `uid=10001(moonlightweb)` |
| 2 | No capabilities | `cap_drop: [ALL]`, no `cap_add` | `CapDrop=["ALL"]`, `CapAdd=null` |
| 3 | No privilege escalation | `no-new-privileges:true` | `SecurityOpt` contains it |
| 4 | Read-only root filesystem | `read_only: true` + tmpfs | `ReadonlyRootfs=true`; write to `/etc` fails |
| 5 | Resource bounds | 2 CPU, 2 GiB, 512 PIDs | `docker inspect` |
| 6 | No Internet Access | `MW_LAN_ONLY=1` | startup log line |
| 7 | No remote admin unlock by default | `remote_admin_enabled=false` seed | `settings.json` |
| 8 | Authentication | PIN + PBKDF2-SHA256 admin password | both flows exercised |
| 9 | Security headers | emitted by the application | `curl -I` |
| 10 | Audit trail | entrypoint → `security.log` | file written at boot |
| 11 | Bounded logs | entrypoint rotates logs > 100 MB at start | implemented; not exercised with a real 100 MB log |

### 2.1 Non-root (1)

The container runs as `moonlightweb`, not root. A compromise inside the app
therefore starts with an unprivileged uid, and cannot `chown`, `mount`, or write
to most of the filesystem.

**Limit:** the process still shares the host kernel. Docker's isolation is
namespaces plus the default seccomp/AppArmor profile, not a VM.

The uid/gid are **pinned to 10001:10001**. `useradd -r` allocates the next free
system id, so a package change can move it and orphan the `/data` volume; a
rebuild must not be able to do that. If you upgrade from a pre-pin build, see
`docs/DEPLOY.md` §3.4 for the one-time `chown`.

### 2.2 No capabilities (2)

`cap_drop: [ALL]` removes every Linux capability. The image needs none because
it binds 8080/8443 (§4.2). This is stronger than the common
`cap_drop: ALL` + `cap_add: NET_BIND_SERVICE` recipe: nothing can be regained.

### 2.3 No new privileges (3)

`no-new-privileges` makes setuid/setgid binaries and file capabilities
ineffective. It also means a future decision to grant `NET_BIND_SERVICE` through
a file capability would silently stop working — which is the intended trade.

### 2.4 Read-only root filesystem (4)

Everything writable is either a tmpfs (`/tmp`, `/run`) or the `/data` volume.
An attacker cannot drop a persistence binary into the image, and a bug cannot
fill the host disk through the overlay.

**Limit:** `/data` is writable by design. It holds settings, certificates and
logs, so it is the part of the system that must be backed up and protected
(§6).

### 2.5 Resource bounds (5)

`cpus: 2.0`, `mem_limit: 2g`, `pids_limit: 512`. The bounds are generous enough
for 1080p60 encoding but stop a runaway process from taking the host with it.

`shm_size: 256m` is functional, not security: WebRTC/SCTP needs more than the
64 MB default with several stream slots.

### 2.6 No Internet Access (6)

`MW_LAN_ONLY=1` is read at runtime by `backend/src/common/Edition.cpp`. It
disables the rendezvous line, STUN, UPnP and the update check, and refuses
"Internet Access" requests. The startup log states it.

**Limit:** this is an application-level switch, not a network ACL. If you need
enforcement independent of the app, use the firewall template and a host
egress policy.

### 2.7 Remote admin unlock off (7)

`AppSettings::remoteAdminEnabled()` defaults to `true`. The entrypoint seeds
`false` on first run, so a machine on the LAN cannot unlock the admin page with
a password until the operator opts in. `--set-admin-password` re-enables it,
which is what the operator is asking for when they run that command.

The seed is *first run only*. It never overwrites a later deliberate change.

### 2.8 Authentication (8)

- **PIN:** six digits, issued by `--new-pin`, held in the running server's
  memory and single-use. There is no persisted PIN, which is why the entrypoint
  does not (and cannot) require one at startup.
- **Admin password:** PBKDF2-SHA256, 210 000 iterations, stored as
  `pbkdf2-sha256$210000$<salt>$<hash>`. Never stored in clear.
- **Rate limiting:** compiled into `AuthManager` and `ConnectionGuard`
  (200 connections per window per IP). These are not configurable through the
  environment, and this repository does not pretend otherwise.

### 2.9 Security headers (9)

The application emits `Content-Security-Policy`, `Strict-Transport-Security`,
`X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff` and
`Referrer-Policy`. They are not injected by a proxy or by this repository's
configuration; a reverse proxy in front must not weaken them.

### 2.10 Audit trail (10)

`entrypoint-secure.sh` appends to
`/data/.local/share/MoonlightWeb/MoonlightWeb/security.log`: uid/gid, port
assignments, the first-run seed, config validation, and log rotations. It is
deliberately small and greppable.

**Limit:** it records entrypoint decisions, not application requests. The
application keeps its own log next to it in `logs/moonlightweb.log`. Rotation
runs at container start, not on a timer: a container left running for months
will grow that file. Restarting on upgrade is what bounds it in practice, and
the container's own stdout/stderr are capped by the `json-file` driver in the
compose file.

---

## 3. Host networking: the trade-off, stated plainly

The compose file uses `network_mode: host`, as upstream does, because:

- WebRTC binds an **ephemeral** UDP port per stream slot; an ephemeral port
  cannot be published in advance on a bridge.
- mDNS (UDP 5353) and SSDP/UPnP are multicast and do not cross Docker's default
  bridge.

**The cost:** the container has no network namespace of its own. Its listeners
*are* host listeners, and `127.0.0.1` inside the container is the host's
loopback. Isolation from the network is therefore not provided by Docker; it is
provided by the application (`MW_LAN_ONLY`) and by the host firewall.

This is a deliberate, documented trade. A bridge variant would harden the
network boundary while breaking discovery and possibly forcing WebRTC onto TCP.

---

## 4. Choices that were rejected

### 4.1 A custom seccomp profile

No profile is shipped. Docker's built-in default applies. An allowlist that has
not been exercised against Qt, WebRTC, SCTP and the native host is more likely
to break media than to stop an attacker, and a broken stream is a security
failure people work around by disabling the profile.

If you want more: run the workload under `strace`/`auditd`, derive the syscall
set, and test every feature — do not copy a generic profile.

### 4.2 Binding 80/443 as non-root

Attempted and rejected, with evidence:

- `NET_BIND_SERVICE` is not delivered to a non-root process reliably across
  hosts. Observed here: `HTTP port 80 unavailable (The address is protected)`,
  followed by a fallback to 8443.
- A file capability would work but `no-new-privileges` deliberately neutralises
  it.
- `net.ipv4.ip_unprivileged_port_start=0` is refused in a host network
  namespace: `sysctl "net.ipv4.ip_unprivileged_port_start" not allowed in host
  network namespace`.

Result: 8080/8443, with a reverse proxy for 443. The reverse proxy also supplies
a certificate a browser will trust.

### 4.3 Mandatory auth at startup

Rejected because it cannot work. The PIN is in-memory and single-use. An
entrypoint that refused to start without one would produce a container that
cannot be `exec`'d into to create one — a restart loop with no exit. The
entrypoint reports the auth state instead; the server enforces the PIN wall.

### 4.4 Rate-limit environment variables

`MW_MAX_CONNECTIONS_PER_IP`, `MW_RATE_LIMIT_PER_MINUTE`, `MW_SESSION_TIMEOUT`,
`MW_CSRF_TOKEN_ENABLED`, `MW_HSTS_ENABLED`, `MW_CSP_ENABLED` and
`MW_DISABLE_ADMIN_UNLOCK` are **not read by this codebase**. They were removed
from the image and compose files rather than left in place to look reassuring.
The real limits are compiled in.

### 4.5 A `security-config.json`

Deleted. Nothing parses it. Settings live in `settings.json`, written by the
application. A second file with a plausible schema is worse than no file: it
invites operators to change values that have no effect.

### 4.6 A firewall script that sets `-P INPUT DROP` by default

`scripts/firewall-rules.sh` is dry-run by default and keeps its rules in a
dedicated `MW_INPUT` chain. `--default-drop` is opt-in, because a script that
flips the INPUT policy while you are connected over SSH is a lockout tool, not a
security tool. It also does not claim to be persistent: save the rules with
`iptables-save`.

---

## 5. Monitoring: what it can and cannot see

The stack covers **host and container** metrics:

- node-exporter: CPU, memory, disk, filesystem, network.
- cAdvisor: per-container CPU/memory, container visibility.
- Prometheus/Alertmanager/Grafana with a placeholder receiver.

It does **not** cover application events. There is no `/metrics` endpoint —
`/metrics` returns the SPA index. Failed logins, certificate expiry and stream
quality are not observable here, and the alert rules do not pretend to cover
them.

The UIs bind to `127.0.0.1`; Grafana's default `admin`/`admin` must be changed
before the port is exposed anywhere.

---

## 6. The backup is a secret

`scripts/backup.sh` archives `/data`, which includes:

- `settings.json` — HMAC key, host signing key, certificate token, admin
  password **hash**;
- `cert/key.pem` — the TLS private key.

A backup is therefore enough to impersonate the server on the LAN. The script
writes archives `0600` under `umask 077`, verifies that `settings.json` is in
the archive before keeping it, and prints the warning. Store backups with the
same care as the volume itself, and encrypt them if they leave the host.

---

## 7. Residual risks

| Risk | Status |
|---|---|
| Kernel/container escape | Not mitigated beyond Docker defaults; host networking increases blast radius |
| Self-signed certificate | Browser trust error by default; use a reverse proxy with a real certificate |
| PIN brute force | Rate-limited in `AuthManager`, but there is no account lockout dashboard |
| No application-level audit | Only the entrypoint's security log and the app log |
| Host firewall not managed | `scripts/firewall-rules.sh` is a template, not applied automatically |
| Windows service account | `MoonlightWebService.ps1` recommends a dedicated account; running as LocalSystem puts the profile under System32 (`WinSystemPath.h`) |
| Monitoring alerts not delivered | Alertmanager receiver is a placeholder |
| Application log growth between restarts | Rotated only at container start; restart periodically or prune `/data/.../logs` |

---

## 8. Re-verifying

```bash
./scripts/security-scan.sh moonlightweb
docker inspect moonlightweb --format '{{json .HostConfig}}' | jq '{Privileged,CapDrop,CapAdd,SecurityOpt,ReadonlyRootfs,Memory,NanoCpus,PidsLimit}'
docker exec moonlightweb sh -c 'curl -k -sI https://localhost:8443/ | head -12'
```

`docs/TEST.md` has the full cycle, including the negative tests (writing to `/`,
clearing and restoring the admin password).
