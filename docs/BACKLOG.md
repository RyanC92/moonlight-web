# Backlog — requested changes not yet implemented

Captured during the hardening/testing session, 2026-10-28. None of these are
started; this file exists so the requests are not lost while testing continues.

## 1. Point the empty-state download link at ViBeShine ✅ DONE

The home page, with no paired host, offers a "download Sunshine" link. It should
suggest **ViBeShine** instead.

- Where: the host-list empty state in the frontend.
- Not yet located — needs a search for the Sunshine download URL/anchor in
  `frontend/`.
- Scope: wording **and** target URL. Renaming the label without changing the
  href would be worse than leaving it.

## 2. Rebrand

Replace the MoonlightWeb identity throughout: product name, logo, window/tray
titles, certificate CN, user-visible strings, package/container names, and the
`MoonlightWeb` state directory names.

- **Licensing constraint:** the project is GPL-3.0. A rebrand must keep the
  copyright notice and credit the original author (see `LICENSE`, `COPYRIGHT`).
  Removing attribution is not a rebrand, it is a licence violation.
- Renaming the state directory (`~/.local/share/MoonlightWeb`) is a data
  migration, not a string edit — existing `settings.json`, `cert/` and pairings
  live there.

## 3. Self-host at a unique URL; remove all moonlightweb.top references ✅ DONE (code)

Every reference to the upstream author's hosted infrastructure must go, because
this fork will run its own.

Known or likely categories:

- **Rendezvous / entry link** — `stream.moonlightweb.top`, the introduction
  server used for Internet Access.
- **Update relay** — `updates.{MW_DOMAIN}` in `README.md` and the update check.
- **Session metrics** — `metrics.{MW_DOMAIN}`.
- **Bootstrap watch / entry page** — `app.moonlightweb.top`, plus the
  `.github/workflows/bootstrap-watch.yml` job that verifies it.
- **Docs and installer links** — `moonlightweb.top` guides, `install.sh`, and
  the package repositories.
- **Container images** — `ghcr.io/linckosz/moonlight-web`.

Note: `MW_LAN_ONLY=1` already suppresses the rendezvous line, STUN, UPnP and the
update check at runtime, so the hardened container does not contact any of these
today. Removing the *references* is still required for the rebrand.

Open question to settle before implementing: does this fork keep Internet
Access at all? If it stays LAN-only, the rendezvous/metrics/update paths can be
deleted outright rather than re-pointed.

## 4. Admin page opens without a password (by design, but misleading)

Found during testing, 2026-10-28. Verified with a PIN-authenticated session from
a non-loopback address (172.21.0.7, via the test proxy):

| Request | Result |
|---|---|
| `GET /api/admin/settings` | `200` — ports, instance name, boolean flags; no secrets |
| `GET /api/admin/token` | `200` `{}` — no admin key granted |
| `POST /api/admin/pin/generate` | `403` |

**Root cause:** `RequestGuard.cpp:284` — reads deliberately do not require admin
privilege ("the admin page has to load and fetch that key in the first place").
Only mutations need the admin key. So this is **intended behaviour, not a
bypass**.

**Two real defects it exposes:**

1. `README.md` states *"Any other request to `/api/admin/*` gets 403."* That is
   false for an authenticated read — it returns 200. The sentence should refer
   to writes.
2. The admin UI shows no read-only state. An operator sees a fully rendered
   admin page, assumes full access, and only discovers the limit when a save
   fails. It should say plainly that changes need the admin password, and
   prompt before the first write.

**Do not** change the read/write split without care: gating reads would break
the page's own unlock flow. The fix is UI clarity plus a doc correction.

### Confirmed in the UI, with the full write chain

Driving the same path with `curl` proves the backend is correct and isolates the
defect to the frontend:

| Step | Result |
|---|---|
| PIN session (remote, 172.21.0.7) | `200` |
| `POST /api/auth/admin-unlock` + correct password | `200 {"status":"ok"}` |
| `GET /api/admin/token` | key issued |
| `POST /api/admin/pin/generate` + `x-mw-admin-key` | `200`, PIN rotated |

A write therefore needs **three** things: an authenticated session, a promoted
(admin) session, and the per-run admin key in `x-mw-admin-key`
(`HttpServer.cpp:869`, `RequestGuard.cpp:292`). The page supplies the key but
never triggers the promotion, so the save is refused and the user is shown a
message that describes the wrong cause.

**Misleading strings to fix** (all in `backend/src/server/routes/SystemRoutes.cpp`):

- `:1122` — `"Admin settings can only be modified from localhost"`
- `:217` and `:1033` — `"Internet access settings can only be modified from localhost"`

When `admin_unlock_available` is true, these should say the admin password is
required (and, ideally, the UI should prompt for it and then retry the save).
The "localhost" wording is only accurate for a caller that is genuinely local
and locked out, which is not this case.

### Status: fixed and verified (2026-10-28)

- `AdminView.js` — `_isLocalhost()` now lets the server's verdict decide once
  `/api/auth/status` has answered; the URL fallback survives only for the moment
  before that answer arrives (or if the request failed). A remote session
  reaching the app under the name `localhost` now gets the unlock prompt instead
  of an editable-looking page.
- `SystemRoutes.cpp` — the three "can only be modified from localhost" strings
  now name the real requirement.
- `README.md` — the blanket "`/api/admin/*` gets 403" claim replaced with the
  actual split: authenticated reads allowed, changes gated.

**Verified end to end** on the running container: the admin page showed the
password field, unlocking revealed the full page, a toggle saved, and
`settings.json` was rewritten afterwards (`15:06:06`) with the unlock recorded
in the app log (`admin password validated successfully` → `Admin access
unlocked`). Security scan still 13 pass / 0 fail. Frontend suites: 90/90 in the
admin and API tests, lint clean; the 10 failures in
`officialInterface`/`bootInterfaceCheck` are pre-existing and reproduce on a
clean tree.

Still open, deliberately not changed: writes require **three** things (session,
promoted session, `x-mw-admin-key`). That is the intended model and the UI now
supplies all three after an unlock.

## 5. Virtual display: use ViBeShine's adapter instead of MttVDD?

Investigated 2026-10-28. **Verdict: no — keep the bundled MttVDD.** ViBeShine's
"virtual display adapter" is not a driver we can point at from a setting; it is a
driver *plus* a private binary control protocol, and installing it requires
granting a self-signed certificate machine-wide trust.

### What it actually is

- **Driver** — `SunshineVirtualDisplayDriver` (UMDF/IddCx, described upstream as
  clean-room): hardware ID `Root\SunshineVirtualDisplay`, device interface class
  `{5f894d6c-3a69-48a2-86ef-e4c671932d63}`, shipped as dll + cat + cer and
  installed by their own ~1,800-line `install.ps1`.
- **Client** — a *separate* MIT repository, `Nonary/libvirtualdisplay`. The
  Windows transport opens the interface path with SetupAPI, `CreateFileW`, then
  `DeviceIoControl` (`src/driver/windows_control_client.cpp`). The protocol is
  versioned and lease-based: API namespace `{a2864284-77fe-4336-a828-00feeC89ebac}`,
  major 3 / minor 8, minimum compatible minor 6; `LeaseId` separate from
  `DisplayId`; create/remove temporary displays, HDR EDID, a frame-ring transport.
- ViBeShine's own host-side glue is `src/platform/windows/virtual_display_sunshine.cpp`,
  ~378 KB.

### Why we cannot simply drive it

1. **No control path exists in our code.** Our Windows VDD stage is a settings
   XML rewritten with the client's resolution, then a SetupAPI node toggle
   (`VirtualDisplay.cpp`, `VirtualDisplayApply.cpp`). There is no device-interface
   client to reuse and no protocol implementation to talk to.
2. **Its device is closed to us.** The INF sets
   `D:P(A;;GA;;;SY)(A;;GA;;;S-1-5-80-…)` on both the node and the control
   interface — SYSTEM plus one service identity, with Administrators
   deliberately absent. Our `--vdisplay-apply` helper runs with an admin token,
   so it would be refused. Reaching the interface means running that helper as
   SYSTEM or rewriting the installed node's DACL.
3. **Its signature model is weaker than ours.** The catalog is signed by a
   **self-signed** certificate (`CN=Sunshine Virtual Display Release Signing`,
   2026–2036, no CA), which their installer adds to `LocalMachine\Root` and
   `TrustedPublisher`. Anyone who obtains that private key can then sign drivers
   this machine trusts. MttVDD is signed by SignPath Foundation, chaining to
   GlobalSign — already trusted, nothing added to the root store.

### Licensing is *not* the blocker

Both the driver and `libvirtualdisplay` are MIT (© 2026 Chase Payne), so they are
compatible with this project's GPL-3.0 and could legally be vendored. The
obstacles are architectural and trust-related, not legal.

### What adopting it would take

Vendor `libvirtualdisplay`, add a control-client stage, host display creation in
a SYSTEM-run helper, and accept the root-store certificate — plus a new
dependency surface to review. Weeks of work, and a wider privilege/trust
footprint than the current pinned-hash + SetupAPI model.

It would buy: per-session create/remove instead of rewriting XML and toggling the
node, HDR-capable EDID, and zero-copy frame push. None of these is a gap today —
MttVDD already matches the client's resolution (`vddmatch`) at up to 240 Hz.

**Revisit if** MttVDD stops being signed or maintained, or if HDR virtual
displays / per-client isolated displays become a requirement. At that point the
right starting point is `libvirtualdisplay`'s own `docs/` and probe tool, not
ViBeShine's integration layer.


