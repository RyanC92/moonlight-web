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
| `MW_DOMAIN` | Domain used for rendezvous, STUN and updates. Empty means the binary falls back to `moonlightweb.top` **at runtime**; `MW_LAN_ONLY=1` is what keeps it off those paths. |
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
