# Self-hosting MoonlightWeb

MoonlightWeb is both the web server and the web interface. The server serves
the frontend, API, authentication and streaming/signalling endpoints together;
there is no separate frontend site to deploy. You can run it on the gaming PC
or on an always-on Linux server and open its interface from a browser.

## Choose where it runs

- **Gaming PC:** install or build MoonlightWeb on that machine to stream its
  displays directly.
- **Separate server, NAS or mini PC:** run the Docker image. This gives you an
  always-on interface and a bridge to Sunshine-compatible hosts; it cannot
  capture the container's screen. Add the gaming PC as a host.

The Docker image is published to GHCR by this repository's CI pipeline when a
version-tag release is built:
`ghcr.io/ryanc92/moonlight-web`. Use a release tag, or `latest` for the newest
published release. If no image has been published yet, build it from a checkout
as shown under [Building from source](#building-from-source).

On its first push, GitHub Container Registry may create the package as private.
The repository owner must change the package visibility to **Public** in the
GitHub Packages settings before other users can pull it without authenticating.

## Start the Docker server

On a Linux host with Docker Engine and Compose installed:

```sh
docker run -d --name moonlightweb \
  --network host \
  --cap-drop ALL --cap-add NET_BIND_SERVICE \
  -v mw-data:/data \
  --restart unless-stopped \
  ghcr.io/ryanc92/moonlight-web:latest
```

Host networking is the recommended setup: it allows WebRTC media, mDNS host
discovery and UPnP to work without additional network configuration. Read
[the Docker guide](../docker/README.md) for alternatives and their limitations.

The container does not open firewall ports for you. Allow the ports on the
server's firewall:

| Port | Protocol | Purpose |
|---|---|---|
| 443 | TCP | HTTPS web interface, API and WebSocket signalling |
| 80 | TCP | HTTP-to-HTTPS redirect |
| 48550-48573 | UDP | WebRTC media and input |

Open the ports only to the networks that need access. You generally do not need
to forward them through your router for LAN-only use.

Set up the two credentials after the container starts:

```sh
docker exec -it moonlightweb moonlightweb --set-admin-password
docker exec moonlightweb moonlightweb --new-pin
docker exec moonlightweb moonlightweb --status
```

Open `https://<server-lan-ip>` in a browser and accept the self-signed
certificate warning on first use. Enter the single-use PIN from `--new-pin`.
The admin password protects configuration changes; the PIN grants access to
the web interface. Keep the named `mw-data` volume: it stores settings,
certificates, paired hosts and the client identity.

## Admin access from a remote computer or VPS

For a headless Ubuntu VPS, create an SSH local port forward from your own
computer to the server's loopback listener. This keeps the Admin interface off
the public internet. Replace `ubuntu` and the example address with your VPS
login and IP:

```sh
ssh -N -L 18080:127.0.0.1:80 ubuntu@203.0.113.10
```

Keep that SSH session open, then open
[`http://localhost:18080/admin`](http://localhost:18080/admin) in a browser on
your computer. The tunnel carries the connection over SSH; the application
receives it on the VPS as a loopback request. You may instead use a private VPN
such as Tailscale and access the server over that private network.

If you use the hardened/public Compose deployment, its private HTTP listener is
8080 rather than 80. Forward that port instead:

```sh
ssh -N -L 18080:127.0.0.1:8080 ubuntu@203.0.113.10
```

Then use the same local URL. Do **not** open port 8080 or 8443 in the VPS
firewall or publish them to the internet. A public domain or reverse-proxy URL
is for the web interface; it does not make a visitor a host-local Admin. The
web-interface PIN and the Remote administration password are separate
credentials: the PIN admits a browser session, while the password unlocks
administration for supported LAN or rendezvous-tunnel peers. The password does
not enable Admin access through an ordinary public-domain URL.
`--enable-internet` is not a setting for exposing the Admin page on your
public domain.

## Give the interface your own URL

For private access, use the LAN address above or a private network such as
Tailscale. For access through your own domain, put a TLS-terminating edge in
front of MoonlightWeb and configure the public hostname. The supported patterns
and their tradeoffs are documented in:

- [Public deployment with your own domain](PUBLIC.md) — a complete Docker
  deployment using Caddy or Cloudflare Tunnel.
- [Edge and reverse-proxy configuration](EDGE.md) — Caddy, Cloudflare Tunnel,
  Tailscale, nginx and other proxy requirements.
- [Hardened deployment](DEPLOY.md) — the non-root image and its Compose setup.

The interface and API must remain on the same origin. A static host by itself
cannot replace the MoonlightWeb server. Do not expose the app's private
listeners (8080/8443) directly to the internet; use the documented proxy
configuration, preserve WebSocket upgrades and forward client addresses
according to the edge guide. Public WebRTC streaming also needs a working UDP
media path; an HTTP-only tunnel may fall back to higher-latency TCP/WebSocket
transport.

## Building from source

Clone this fork and its required submodules, then build the image from the
repository root:

```sh
git clone --recurse-submodules https://github.com/RyanC92/moonlight-web.git
cd moonlight-web
docker build -t moonlightweb:local .
```

Start the locally built image with the same run command, replacing
`ghcr.io/ryanc92/moonlight-web:latest` with `moonlightweb:local`. See the root
[Dockerfile](../Dockerfile) for the Debian build/runtime stages and
[CONTRIBUTING.md](../CONTRIBUTING.md) for native development setup.

## Back up and update

Back up `/data` while the container is stopped; it includes pairing identity and
cannot be regenerated from a host. To update a published image:

```sh
docker pull ghcr.io/ryanc92/moonlight-web:latest
docker stop moonlightweb
docker rm moonlightweb
# Re-run the docker run command above.
```

The named volume remains when the container is removed. For Compose-based
operations, backups and troubleshooting, follow the full
[Docker reference](../docker/README.md).
