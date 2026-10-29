# Building MoonlightWeb

Two build paths: the upstream image (`Dockerfile`) and the hardened image
(`docker/Dockerfile.hardened`). They share the same build stage; only the
runtime stage differs.

## Requirements

- Docker 20.10+ with BuildKit (default in current Docker)
- ~2 GB disk for the build cache, ~4 GB RAM free (CMake runs with `-j nproc`)
- No host Qt or compilers: everything is built inside the build stage

## Hardened image

```bash
docker build -f docker/Dockerfile.hardened -t moonlightweb-hardened:latest .
```

That is the exact command used to produce and test the image described in
`docs/DEPLOY.md`.

### Stage layout

| Stage | Base | Contents |
|---|---|---|
| `build` | `debian:trixie` | compilers, CMake/Ninja, Qt 6 dev, OpenSSL dev; compiles and stages to `/stage` |
| `runtime` | `debian:trixie-slim` | Qt runtime, `jq`, `curl`; non-root user; no build tools |

The runtime stage copies `/stage` from the build stage, so no compiler,
package manager metadata or source tree reaches the final image.

### Build arguments

| Argument | Effect |
|---|---|
| `MW_VERSION` | Version string baked into the binary (`--version`, update check, User-Agent). Empty derives from a git tag; the build context excludes `.git`, so a local build reports `0.0.0-dev`. |
| `MW_DOMAIN` | Domain used for rendezvous, STUN and updates. Empty means no upstream domain is used; this fork is LAN-only by default and does not contact any upstream infrastructure. |
| `MW_PDNS_TOKEN` | Shared API key for the update relay and session metrics, and how an official build is distinguished. Empty = self-built; those calls are skipped. |
| `DEBIAN_RELEASE` | Defaults to `trixie`. |

Example:

```bash
docker build \
  -f docker/Dockerfile.hardened \
  --build-arg MW_VERSION=1.2.3 \
  -t moonlightweb-hardened:1.2.3 .
```

These are build-stage arguments. The runtime stage is a separate `FROM`, and
`docker history` on the result contains none of them — but values baked into the
binary are readable from the binary, exactly as with the upstream `.deb`.

### Build context

`.dockerignore` is an allowlist: only `backend/`, `frontend/` and `docker/` are
sent. Local `build/` trees, `node_modules`, `.git` and generated output stay
out, which keeps the context ~1 MB instead of hundreds.

### Verifying a build

```bash
docker image ls moonlightweb-hardened
docker run --rm --entrypoint moonlightweb moonlightweb-hardened:latest --version
docker inspect moonlightweb-hardened --format '{{.Config.User}}'
```

Expected: `moonlightweb:moonlightweb` (non-root).

## Upstream image

```bash
docker build -t moonlightweb:latest .
```

Differences from the hardened image: runs as root, binds 80/443, no
read-only rootfs, no resource limits baked in, `ENTRYPOINT` is
`docker/entrypoint.sh` rather than `docker/entrypoint-secure.sh`.

## Windows x64 host build

The container is the recommended deployment; this path produces `MoonlightWeb.exe`
for a Windows host, which is what `scripts/MoonlightWebService.ps1` supervises.

### Requirements

| Component | Version used | Notes |
|---|---|---|
| Visual Studio Build Tools 2022 | 17.14, MSVC 14.44 (v143) | workload **Desktop development with C++**; brings the compiler, Windows SDK and its own CMake + Ninja |
| Qt 6 MSVC 2022 64-bit | 6.10.3 | must include the **WebSockets** module; any 6.x kit works |
| OpenSSL | none to install | `backend/libs/windows` ships x64 and arm64 import libs, DLLs and headers; CMake pins them |
| Python + `aqtinstall` | optional | installs Qt without a Qt account |

`build_msvc.bat` calls `vswhere` to enter the MSVC environment and takes the
highest `C:\Qt\6.*\msvc2022_64` kit. Set `QTDIR` (or `CMAKE_PREFIX_PATH`) to
override, and `BUILD_JOBS` to cap parallelism on a small machine.

### Install Qt without a Qt account

```powershell
pip install aqtinstall
aqt install-qt windows desktop 6.10.3 win64_msvc2022_64 -O C:\Qt --modules qtwebsockets
```

Qt's own online installer works too, but demands an account. Note that aqt's
metadata path for **6.11.x returns 404** from `download.qt.io`, which is why the
6.10 line is documented here; 6.8.x and 6.10.x resolve normally.

### Build

```powershell
cmd /c backend\build_msvc.bat
```

Output: `build\MoonlightWeb.exe`. Submodules are fetched on the first run if they
are missing; a normal clone already has them.

### Make the binary self-contained

Qt DLLs are not next to the executable, so deploy them before copying it
anywhere:

```powershell
C:\Qt\6.10.3\msvc2022_64\bin\windeployqt.exe --release --no-translations build\MoonlightWeb.exe
```

OpenSSL's `libcrypto-3-x64.dll` and `libssl-3-x64.dll` come from
`backend/libs/windows/lib/x64` and must sit next to the exe as well. Do **not**
run `--no-openssl`: the server terminates TLS itself.

### Verify

```powershell
build\MoonlightWeb.exe --version
build\MoonlightWeb.exe --status
```

Then open `https://localhost` and confirm the UI loads. The Windows build shares
`frontend/` and `backend/` with the image, so a fix verified in one is present in
the other.

## Rebuilding for base-image updates

The image deliberately does not bundle Qt or OpenSSL by hand: both come from the
Debian base. Security updates arrive by rebuilding:

```bash
docker build --pull -f docker/Dockerfile.hardened -t moonlightweb-hardened:latest .
```

## Troubleshooting

**Build killed (OOM).** CMake runs `-j $(nproc)`. Cap it by editing the build
stage to `cmake --build /tmp/build -j 2`, or give Docker Desktop more memory.

**`qmake`/Qt not found.** The build stage installs `qt6-base-dev` and
`qt6-websockets-dev`; a local Qt installation is not used and not needed.

**Submodule or patch errors.** The build copies `backend/` from the context; a
submodule's `.git` file is excluded on purpose (`.dockerignore`), so the CMake
patch step runs against plain files. A stale local `backend/build` tree is also
excluded.

**Disk full during export.** The build stage is large; prune with
`docker builder prune` and retry.