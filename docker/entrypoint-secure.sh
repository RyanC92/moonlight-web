#!/bin/sh
# =============================================================================
#  MoonlightWeb container entrypoint (hardened).
#
#  Same contract as docker/entrypoint.sh — operator commands pass straight
#  through, settings are applied from the environment, stale locks are cleared,
#  then exec so the server is PID 1 — plus the hardening below.
#
#  HARDENING IN THIS VERSION
#    - Runs as a non-root user; every ownership/chmod is best-effort and never
#      fatal, because a non-root process cannot chown.
#    - Validates MW_HTTP_PORT / MW_HTTPS_PORT before writing them, instead of
#      trusting the environment.
#    - Writes MW_DOMAIN into settings.json (`domain`), which is what actually
#      makes the public hostname trusted; the variable alone is not.
#    - Validates settings.json and logs the result to a dedicated security log.
#    - Sets restrictive modes on settings.json and the security log.
#    - Samples and rotates oversized logs.
#    - Prints an explicit auth posture banner (what is still to be done).
#
#  IMPORTANT — what is deliberately NOT here
#    The access PIN is issued on demand into the *running* server's memory; it
#    is not a persisted setting. Refusing to start when "no PIN exists" is
#    therefore a deadlock: the container that the operator would run
#    `moonlightweb --new-pin` against never starts. Auth is enforced by the
#    server itself (the browser stops at a PIN wall), and this entrypoint
#    reports that state instead of blocking on it.
# =============================================================================
set -eu

APP=/opt/moonlightweb/MoonlightWeb
# Qt's AppDataLocation for organization=application=MoonlightWeb, under the
# $HOME the image sets to the volume. settings.json, cert/, the access PIN and
# the logs all live here; QSettings (paired hosts + the Moonlight client
# identity) sits next door in $HOME/.config/MoonlightWeb.
DATA="$HOME/.local/share/MoonlightWeb/MoonlightWeb"
SETTINGS="$DATA/settings.json"
SECLOG="$DATA/security.log"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-moonlightweb}"

log_security() {
    mkdir -p "$DATA" 2>/dev/null || true
    printf '[SECURITY] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$SECLOG" 2>/dev/null || true
}

# ── Operator commands run against the *other* process ────────────────────────
# `--status`, `--new-pin`, `--set-admin-password`, `--clear-admin-password` and
# `--enable-internet` talk to the instance that is already running and exit.
# None of the preparation below applies to them — and the lock cleanup would be
# actively wrong, since the lock they must not disturb belongs to a live server.
for arg in "$@"; do
    case "$arg" in
        --status|--new-pin|--set-admin-password|--clear-admin-password|--enable-internet|--version|-v|--help|-h)
            exec "$APP" "$@"
            ;;
    esac
done

# ── Make $HOME usable ────────────────────────────────────────────────────────
mkdir -p "$DATA" "$HOME/.config" "$RUNTIME_DIR"
chmod 700 "$DATA" "$RUNTIME_DIR" 2>/dev/null || true

log_security "entrypoint: hardening applied, uid=$(id -u) gid=$(id -g)"

# ── Settings that must be decided before the listeners bind ──────────────────
# Same three as the upstream entrypoint: the two listener ports and UPnP. They
# are re-applied on every start because the server writes the port it actually
# bound back into settings.json.
apply_setting() {
    _key=$1
    _value=$2
    [ -n "$_value" ] || return 0
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    _tmp="$SETTINGS.tmp"
    if jq --argjson v "$_value" ".\"$_key\" = \$v" "$SETTINGS" > "$_tmp" 2>/dev/null; then
        mv "$_tmp" "$SETTINGS"
    else
        rm -f "$_tmp"
        echo "entrypoint: could not set $_key in $SETTINGS (is it valid JSON?)" >&2
        log_security "config-error: could not set $_key"
    fi
}

# Same, for a string value. `--arg` quotes it; `--argjson` would try to parse it.
apply_string_setting() {
    _key=$1
    _value=$2
    [ -n "$_value" ] || return 0
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    _tmp="$SETTINGS.tmp"
    if jq --arg v "$_value" ".\"$_key\" = \$v" "$SETTINGS" > "$_tmp" 2>/dev/null; then
        mv "$_tmp" "$SETTINGS"
    else
        rm -f "$_tmp"
        echo "entrypoint: could not set $_key in $SETTINGS (is it valid JSON?)" >&2
        log_security "config-error: could not set $_key"
    fi
}

# Plain POSIX shell: no `[[`, so this runs under dash as well as bash.
valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

if [ -n "${MW_HTTP_PORT:-}" ]; then
    if valid_port "$MW_HTTP_PORT"; then
        apply_setting http_port "$MW_HTTP_PORT"
        log_security "setting http_port=$MW_HTTP_PORT applied"
    else
        echo "entrypoint: refusing invalid MW_HTTP_PORT='$MW_HTTP_PORT'" >&2
        log_security "config-error: invalid MW_HTTP_PORT='$MW_HTTP_PORT'"
        exit 1
    fi
fi

if [ -n "${MW_HTTPS_PORT:-}" ]; then
    if valid_port "$MW_HTTPS_PORT"; then
        apply_setting https_port "$MW_HTTPS_PORT"
        log_security "setting https_port=$MW_HTTPS_PORT applied"
    else
        echo "entrypoint: refusing invalid MW_HTTPS_PORT='$MW_HTTPS_PORT'" >&2
        log_security "config-error: invalid MW_HTTPS_PORT='$MW_HTTPS_PORT'"
        exit 1
    fi
fi

case "${MW_UPNP:-}" in
    0|no|false) apply_setting upnp_enabled false ;;
    1|yes|true) apply_setting upnp_enabled true ;;
esac

# ── The name this host answers to ────────────────────────────────────────────
# MW_DOMAIN is NOT, by itself, the name the server serves: AppSettings::domain()
# returns the `domain` key from settings.json when it holds a valid FQDN, and
# returns EMPTY otherwise — the variable is only the base for the retired
# <uid>.<domain> name it must refuse. Without this step a container started with
# MW_DOMAIN set still treats its public hostname as foreign: every request logs
# "Local privilege denied for untrusted Host", the DNS-rebinding warning, and
# any edge that presents the real name gets no trust at all.
#
# Applied on every start, like the ports, so changing the domain in .env takes
# effect on the next `up -d` instead of requiring a fresh volume.
valid_domain() {
    case "$1" in
        ''|.*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
    esac
    case "$1" in
        *.*) return 0 ;;
    esac
    return 1
}

if [ -n "${MW_DOMAIN:-}" ]; then
    # Browsers send Host lowercased, and the server compares it byte for byte
    # against the stored value, so normalise once, here.
    _domain=$(printf '%s' "$MW_DOMAIN" | tr 'A-Z' 'a-z')
    if valid_domain "$_domain"; then
        _prev_domain=$(jq -r '.domain // ""' "$SETTINGS" 2>/dev/null || echo "")
        apply_string_setting domain "$_domain"
        if [ "$_prev_domain" != "$_domain" ]; then
            log_security "setting domain=$_domain applied"
        fi
    else
        echo "entrypoint: refusing invalid MW_DOMAIN='$MW_DOMAIN' (expected a bare FQDN such as mw.example.com)" >&2
        log_security "config-error: invalid MW_DOMAIN='$MW_DOMAIN'"
        exit 1
    fi
fi

# ── Remote admin unlock: off by default (seed once) ──────────────────────────
# `remote_admin_enabled` is a real persisted setting (AppSettings.cpp; default
# true). A hardened deployment should not let a machine on the network unlock
# the admin page with a password unless the operator asks for that, so seed it
# false on first run. Seed-if-absent, not every start: an operator who turns it
# on (or runs --set-admin-password, which enables it) must not have that
# silently reverted by the next restart.
if [ -f "$SETTINGS" ] && ! jq -e 'has("remote_admin_enabled")' "$SETTINGS" > /dev/null 2>&1; then
    apply_setting remote_admin_enabled false
    log_security "seeded remote_admin_enabled=false (first run)"
fi

# ── Stale single-instance lock ───────────────────────────────────────────────
# See docker/entrypoint.sh: after a `docker kill`, OOM kill or host reboot the
# lock left on the volume names PID 1, and the replacement container is also
# PID 1. Safe to delete here: the operator commands above already left via exec.
rm -f "$DATA/moonlightweb.lock" "$DATA/moonlightweb-tray.lock"

# ── File permissions ─────────────────────────────────────────────────────────
# Best-effort only. A non-root process cannot chown, and the image already owns
# the volume, so failures here are expected and non-fatal.
[ -f "$SECLOG" ] || : > "$SECLOG"
if [ -f "$SETTINGS" ]; then
    chmod 600 "$SETTINGS" 2>/dev/null || true
fi
chmod 600 "$SECLOG" 2>/dev/null || true
for _entry in "$DATA"/*; do
    [ -d "$_entry" ] && chmod 700 "$_entry" 2>/dev/null || true
done

# ── Configuration validation ─────────────────────────────────────────────────
# Non-fatal: a damaged settings.json is reported and then handed to the server,
# which rewrites it with defaults. Refusing to boot would leave the operator
# with a container that cannot be exec'd into to repair it.
if [ -f "$SETTINGS" ]; then
    if jq -e . "$SETTINGS" > /dev/null 2>&1; then
        log_security "config-ok: $SETTINGS is valid JSON"
    else
        echo "entrypoint: WARNING $SETTINGS is not valid JSON; the server will rewrite it" >&2
        log_security "config-warn: $SETTINGS is not valid JSON"
    fi
fi

# ── Log rotation ─────────────────────────────────────────────────────────────
# Nothing depends on logrotate here: rotate any log file the server grew past
# 100 MB, keeping one previous copy. The server's own log lives in logs/, while
# the entrypoint's security log sits at the top of $DATA — scan both.
rotate_logs() {
    _max_bytes=104857600
    for _log in "$DATA"/*.log "$DATA"/logs/*.log; do
        [ -f "$_log" ] || continue
        _size=$(wc -c < "$_log" 2>/dev/null || echo 0)
        if [ "$_size" -gt "$_max_bytes" ]; then
            mv "$_log" "$_log.1" 2>/dev/null || true
            : > "$_log" 2>/dev/null || true
            log_security "log-rotate: $(basename "$_log") exceeded 100MB"
        fi
    done
}
rotate_logs

# ── Auth posture banner ──────────────────────────────────────────────────────
# The container cannot finish setup on its own: the PIN is typed into a browser
# on another device. Say so once, at the top of `docker logs`.
_admin_set=no
[ -f "$SETTINGS" ] && jq -e 'has("admin_password")' "$SETTINGS" > /dev/null 2>&1 && _admin_set=yes

_name="${HOSTNAME:-}"
[ -n "$_name" ] || _name="$(cat /etc/hostname 2>/dev/null)"
[ -n "$_name" ] || _name="<container>"

echo
echo "  ┌─────────────────────────────────────────────────────────────────────┐"
echo "  │ MoonlightWeb (hardened image)                                       │"
echo "  │                                                                     │"
if [ "$_admin_set" = yes ]; then
echo "  │ admin password: set                                                 │"
else
echo "  │ admin password: NOT SET  ->  docker exec -it $_name moonlightweb --set-admin-password"
fi
echo "  │ access PIN:     issued per device  ->  docker exec $_name moonlightweb --new-pin"
echo "  │ status / URL:                      ->  docker exec $_name moonlightweb --status"
echo "  │                                                                     │"
echo "  │ Security: non-root, cap_drop ALL, no-new-privs, read-only rootfs,   │"
echo "  │ resource limits — when deployed with docker-compose.hardened.yml.   │"
echo "  └─────────────────────────────────────────────────────────────────────┘"
echo

exec "$APP" "$@"
