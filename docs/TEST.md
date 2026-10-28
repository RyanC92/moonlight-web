# Testing the hardened deployment

This is the cycle that was actually run against
`moonlightweb-hardened:latest`. Every command below was executed; the "expect"
lines are the observed output, not aspirations. Anything that could not run on
the test host is listed in §10.

**Test host:** Windows 11, Docker Desktop 29.9.2 (Linux containers), Docker
Compose v5.6.1. Because Docker Desktop's host networking belongs to its VM, all
HTTP checks run *inside* the container. On a Linux host the same checks can be
made from the host against `127.0.0.1`.

> **Repository note.** Upstream's `.gitignore` ignores `docs/*` except a
> whitelist. The docs added here (`DEPLOY.md`, `BUILD.md`, `TEST.md`,
> `HARDENING.md`) are therefore invisible to `git status` until force-added:
>
> ```bash
> git add -f docs/DEPLOY.md docs/BUILD.md docs/TEST.md docs/HARDENING.md
> ```

---

## 0. Prerequisites

```powershell
docker version --format '{{.Server.Version}}'
docker compose version --short
docker image ls moonlightweb-hardened
```

If the image does not exist, run §1.

---

## 1. Build

```powershell
docker build -f docker/Dockerfile.hardened -t moonlightweb-hardened:latest .
```

Expect a successful multi-stage build (~3 minutes cold). Verify:

```powershell
docker image ls moonlightweb-hardened
docker inspect moonlightweb-hardened --format '{{.Config.User}}'
docker run --rm --entrypoint moonlightweb moonlightweb-hardened:latest --version
```

| Check | Expected |
|---|---|
| image size | 601 MB on disk (measured) |
| `Config.User` | `moonlightweb:moonlightweb` |
| `--version` | `MoonlightWeb 0.0.0-dev` (or the `MW_VERSION` baked in) |

---

## 2. Deploy

```powershell
docker compose -f docker/docker-compose.hardened.yml up -d
Start-Sleep -Seconds 20
docker compose -f docker/docker-compose.hardened.yml ps
```

Expected:

```
NAME           IMAGE                          STATUS
moonlightweb   moonlightweb-hardened:latest   Up (healthy)
```

If it is restarting, read `docker logs moonlightweb`. The known failure modes
are all in `docs/DEPLOY.md` §8; the most common is a host that cannot give the
non-root user an unprivileged port, which is why the image uses 8080/8443.

### 2.1 Reaching the container from Windows or macOS (test bench only)

`network_mode: host` is the Linux VM's namespace under Docker Desktop, so a
browser on the desktop cannot reach the container at `localhost:8080/8443`.
Container-side checks in §3–§9 still work; only the browser needs a path in.

```powershell
docker compose -f docker/docker-compose.testaccess.yml up -d
docker ps --filter name=mw-testaccess --format "{{.Names}}`t{{.Status}}"
curl.exe -sk -o NUL -w "https 18443 -> %{http_code}`n" https://localhost:18443/api/health --max-time 10
```

Expect `mw-testaccess   Up ...` and `https 18443 -> 200`, then open
`https://localhost:18443` and accept the self-signed certificate. This is the
same certificate a direct connection serves — the sidecar forwards raw TCP and
rewrites nothing.

Two consequences of the bench, both expected:

- The server sees the sidecar's bridge address, not `127.0.0.1`. The admin page
  therefore renders its **password unlock** prompt rather than the local admin
  view. Enter the password set with `--set-admin-password`; the prompt is the
  correct behaviour, not a fault. It is also why `AdminView` must trust
  `/api/auth/status` over the name in the address bar.
- WebRTC media cannot cross the VM boundary, so a stream will fall back or not
  start. See §10.

Do not deploy this file on a server. On a Linux host the listeners are reachable
directly and the sidecar is unnecessary.

---

## 3. Runtime posture

```powershell
docker inspect moonlightweb --format 'Privileged={{.HostConfig.Privileged}} CapDrop={{json .HostConfig.CapDrop}} CapAdd={{json .HostConfig.CapAdd}} NoNewPrivs={{json .HostConfig.SecurityOpt}} ReadOnly={{.HostConfig.ReadonlyRootfs}} User={{.Config.User}} Net={{.HostConfig.NetworkMode}} Mem={{.HostConfig.Memory}} NanoCpus={{.HostConfig.NanoCpus}} Pids={{.HostConfig.PidsLimit}}'
```

Expect exactly:

```
Privileged=false CapDrop=["ALL"] CapAdd=null NoNewPrivs=["no-new-privileges:true"] ReadOnly=true User=moonlightweb:moonlightweb Net=host Mem=2147483648 NanoCpus=2000000000 Pids=512
```

Also confirm the process is not root and the filesystem is read-only:

```powershell
docker exec moonlightweb id
docker exec moonlightweb sh -c 'touch /etc/should-fail 2>&1 || echo "rootfs is read-only"'
```

Expected: `uid=10001(moonlightweb) gid=10001(moonlightweb)` and a write failure.

---

## 4. Web listeners

```powershell
docker exec moonlightweb sh -c 'curl -k -s -o /dev/null -w "https 8443 -> %{http_code}\n" https://localhost:8443/; curl -s -o /dev/null -w "http 8080 -> %{http_code}\n" http://localhost:8080/'
docker exec moonlightweb curl -k -s https://localhost:8443/api/health
```

Expected:

```
https 8443 -> 200
http 8080 -> 200
{"debug":false,"name":"docker-desktop","status":"ok","verbose":false,"version":"0.0.0-dev"}
```

`/metrics` deliberately returns the SPA index, not metrics:

```powershell
docker exec moonlightweb sh -c 'curl -k -s https://localhost:8443/metrics | head -c 20'
```

Expected: `<!doctype html>` — proof that no metrics endpoint exists, which is why
the monitoring stack does not scrape the app.

### 4.1 Security headers

```powershell
docker exec moonlightweb curl -k -sI https://localhost:8443/
```

Expect all of:

```
Content-Security-Policy: default-src 'self'; ...
Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
```

These come from the application, not from the container configuration. No
header is added by the image.

---

## 5. Configuration written by the entrypoint

```powershell
docker exec moonlightweb sh -c 'cat /data/.local/share/MoonlightWeb/MoonlightWeb/security.log'
docker exec moonlightweb sh -c 'jq "{http_port,https_port,upnp_enabled,remote_admin_enabled}" /data/.local/share/MoonlightWeb/MoonlightWeb/settings.json'
```

Expected: a security log with `hardening applied`, the two port assignments,
`seeded remote_admin_enabled=false (first run)` and `config-ok`; and ports
8080/8443, `upnp_enabled: false` (UPnP is off under LAN-only) and
`remote_admin_enabled: false`.

The seed is first-run only; §6.1 proves it does not overwrite a later change.

---

## 6. Authentication flows

`--set-admin-password` reads the password from stdin. Piped, it does not prompt
for confirmation:

```powershell
"Test-Password-12345" | docker exec -i moonlightweb moonlightweb --set-admin-password
docker exec moonlightweb sh -c 'jq -r .admin_password /data/.local/share/MoonlightWeb/MoonlightWeb/settings.json'
```

Expected: `Admin password set.` and a value beginning
`pbkdf2-sha256$210000$…` — a hash, never the password.

Issue a PIN:

```powershell
docker exec moonlightweb moonlightweb --new-pin
```

Expected: a six-digit PIN and the note that it is single-use. It exists only in
the running server's memory; nothing is written to disk.

Status:

```powershell
docker exec moonlightweb moonlightweb --status
```

Expected: `running (headless)`, the URLs (`https://<host>:8443`), `Access PIN
already used` (after a PIN was issued) and the admin password state.

### 6.1 The first-run seed does not clobber a later change

`--set-admin-password` enables remote admin. Restart and confirm the entrypoint
does not force it back to `false`:

```powershell
docker compose -f docker/docker-compose.hardened.yml restart
docker exec moonlightweb sh -c 'jq .remote_admin_enabled /data/.local/share/MoonlightWeb/MoonlightWeb/settings.json'
```

Expected: `true`.

### 6.2 Rejections (negative tests)

```powershell
$b = Join-Path $env:TEMP "wrongpin.json"; '{"pin":"000000"}' | Set-Content -Path $b -NoNewline -Encoding ascii
curl.exe -sk -X POST https://localhost:18443/api/auth/validate -H "Content-Type: application/json" --data-binary "@$b" -w "`nHTTP %{http_code}`n" --max-time 8
curl.exe -sk -X POST https://localhost:18443/api/admin/settings -H "Content-Type: application/json" -H "Origin: https://evil.example" -d "{}" -w "`nHTTP %{http_code}`n" --max-time 8
curl.exe -sk -o NUL -w "unauth read -> %{http_code}`n" https://localhost:18443/api/admin/settings --max-time 8
```

Expected, in order:

```
{"error":"invalid_pin","lockout_seconds":0,"remaining":2,"status":"error"}   HTTP 401
{"error":"cross_site_request_blocked"}                                      HTTP 403
unauth read -> 401
```

Write JSON bodies to a file and pass `--data-binary "@file"`. Inline JSON in
PowerShell lets `!` and quote escaping corrupt the payload, which produces a
`400` that looks like an application fault.

### 6.3 The admin write chain

An authenticated read of `/api/admin/*` succeeds — that is how the page loads
the data behind its unlock prompt. A **change** additionally needs a promoted
session and the per-run key:

```powershell
$jar  = Join-Path $env:TEMP "mw-cookies.txt"
$body = Join-Path $env:TEMP "unlock.json"; '{"password":"<the password>"}' | Set-Content -Path $body -NoNewline -Encoding ascii
curl.exe -sk -b $jar -c $jar -X POST https://localhost:18443/api/auth/admin-unlock -H "Content-Type: application/json" --data-binary "@$body" -w "`nHTTP %{http_code}`n" --max-time 8
$key = (curl.exe -sk -b $jar https://localhost:18443/api/admin/token | ConvertFrom-Json).token
curl.exe -sk -b $jar -X POST https://localhost:18443/api/admin/pin/generate -H "Content-Type: application/json" -H "x-mw-admin-key: $key" -d "{}" -w "`nHTTP %{http_code}`n" --max-time 8
```

Expected: `{"status":"ok"}` then a new PIN, both `HTTP 200`. A `403` here with
an unlocked session means the `x-mw-admin-key` header is missing
(`HttpServer.cpp:869`, `RequestGuard.cpp:292`).

The browser equivalent is: PIN → Admin → password prompt → unlock → toggle a
setting → save. Confirm the write landed, not just that the UI said so:

```powershell
docker exec moonlightweb sh -c 'ls -l --time-style=+%H:%M:%S /data/.local/share/MoonlightWeb/MoonlightWeb/settings.json'
docker exec moonlightweb sh -c 'grep -iE "admin password validated|Admin access unlocked" /data/.local/share/MoonlightWeb/MoonlightWeb/logs/moonlightweb.log | tail -3'
```

The file's mtime must move and the log must show the validation followed by the
unlock. This is the check that would have caught the `AdminView._isLocalhost()`
defect described in `docs/BACKLOG.md`.

---

## 7. Security scan

On a host with the Docker CLI:

```bash
./scripts/security-scan.sh moonlightweb
```

On Windows, or anywhere the CLI is awkward, run it in a container:

```powershell
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${PWD}/scripts:/scripts:ro" docker:cli sh /scripts/security-scan.sh moonlightweb
```

Expected on a healthy, configured stack: **0 failures**. Warnings are expected
where they describe a deliberate choice:

- `no capabilities added (fine if ports are >1024)` — the image binds 8080/8443.
- `admin password not set` — only until §6 is run.

Exit code is 0 only when there are no failures, so it can gate a deployment.

---

## 8. Backup and restore

Create a backup:

```powershell
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${PWD}:/work" -w /work docker:cli sh scripts/backup.sh
```

Expected: `Wrote ./backups/moonlightweb-<timestamp>.tar.gz (~13 KiB)` and the
warning that the archive can impersonate the server (it holds
`settings.json`, `cert/key.pem`, the HMAC key and the admin password hash).

Prove the restore restores, rather than merely exiting 0:

```powershell
# 1. record the hash
docker exec moonlightweb sh -c 'jq -r .admin_password /data/.local/share/MoonlightWeb/MoonlightWeb/settings.json'

# 2. destroy it (confirmation is read from stdin)
"yes" | docker exec -i moonlightweb moonlightweb --clear-admin-password
docker exec moonlightweb sh -c 'jq -r .admin_password /data/.local/share/MoonlightWeb/MoonlightWeb/settings.json'
# expected: null

# 3. restore the archive made in step 1
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${PWD}:/work" -w /work docker:cli sh scripts/backup.sh --restore backups/<file>.tar.gz --yes

# 4. the same hash must be back
Start-Sleep -Seconds 8
docker exec moonlightweb sh -c 'jq -r .admin_password /data/.local/share/MoonlightWeb/MoonlightWeb/settings.json'
docker ps --filter name=moonlightweb --format "{{.Status}}"
```

Observed: the exact pre-restore `pbkdf2-sha256$…` string returned, and the
container came back `Up (healthy)`.

---

## 9. Monitoring

```powershell
docker compose -f docker/docker-compose.monitoring.yml up -d
Start-Sleep -Seconds 20
curl.exe -s "http://localhost:9090/api/v1/targets"
```

Expected in the JSON: three targets, all `"health":"up"` —
`prometheus`, `node-exporter`, `cadvisor`.

```powershell
curl.exe -s -o NUL -w "prometheus %{http_code}\n" http://localhost:9090/-/ready
curl.exe -s -o NUL -w "grafana %{http_code}\n" http://localhost:3000/login
curl.exe -s -o NUL -w "alertmanager %{http_code}\n" http://localhost:9093/-/ready
```

Expected: `200` for all three. Grafana's first login is `admin` / `admin`
(change it). Alerts are **not delivered**: the receiver in
`monitoring/alertmanager.yml` is a placeholder.

Cleanup:

```powershell
docker compose -f docker/docker-compose.monitoring.yml down
```

Add `-v` only if you also want to discard the monitoring databases.

---

## 10. Not covered by this cycle

| Item | Why | How to test it |
|---|---|---|
| `scripts/firewall-rules.sh --apply` | test host is Windows; needs live iptables | Linux VM: dry-run, then `--apply` with a console you can recover from |
| `scripts/MoonlightWebService.ps1 install` | no NSSM and no Windows build on the test host | Windows host with the MSVC build + NSSM (see `docs/DEPLOY.md`) |
| Windows x64 build | no MSVC/Qt toolchain here | `cmd /c backend\build_msvc.bat` on Windows |
| Real WebRTC streaming | needs a Moonlight/Sunshine host and a browser | pair a host, start a stream, check media |
| Host networking from the Windows host | Docker Desktop host networking is the VM's | deploy on Linux and `curl https://<host>:8443`; for UI testing only, the sidecar in §2.1 |

A test run is complete when §3–§9 pass. A deployment is usable when, in
addition, the first pin has been entered in a browser and a stream has started.

---

## 11. Teardown

```powershell
# test bench first, if it was used
docker compose -f docker/docker-compose.testaccess.yml down

# keep the volume
docker compose -f docker/docker-compose.hardened.yml down

# discard all state (settings, certificates, paired hosts)
docker compose -f docker/docker-compose.hardened.yml down -v
```

`docker compose ... down` without `-v` is the safe one: the named volume
`docker_mw-data` survives and the next `up` reuses the existing identity.
