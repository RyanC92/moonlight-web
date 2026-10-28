#!/bin/sh
# =============================================================================
#  MoonlightWeb backup and restore.
#
#  The whole `/data` volume is the unit of backup. It holds everything the
#  container needs to come back as itself:
#
#      .local/share/MoonlightWeb/MoonlightWeb/
#          settings.json          ports, UPnP, admin password hash,
#                                 HMAC key, host signing key, certificate token
#          cert/                  the TLS certificate and key
#          logs/                  server log
#          security.log           entrypoint security events
#          provisioning.status.json
#      .config/MoonlightWeb/      QSettings: paired hosts + client identity
#
#  That is also why a backup is sensitive: settings.json and cert/key.pem are
#  enough to impersonate this server on the LAN. Files are written 0600 and the
#  directory 0700.
#
#  USAGE
#      ./scripts/backup.sh                     back up now
#      ./scripts/backup.sh --list              list existing backups
#      ./scripts/backup.sh --restore FILE      restore one (stops the container)
#      ./scripts/backup.sh --restore FILE --yes  no confirmation prompt
#
#  ENVIRONMENT
#      MOONLIGHTWEB_CONTAINER  container name        (default: moonlightweb)
#      BACKUP_DIR              where archives go    (default: ./backups)
#      RETENTION_DAYS          prune older backups  (default: 30)
#
#  Requires a running Docker CLI on the host. The archive is streamed out of the
#  container with `tar`, so nothing is written to the read-only root filesystem.
# =============================================================================
set -eu

CONTAINER="${MOONLIGHTWEB_CONTAINER:-moonlightweb}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
APP_IMAGE="${MOONLIGHTWEB_IMAGE:-moonlightweb-hardened:latest}"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_container() {
    docker inspect "$CONTAINER" > /dev/null 2>&1 ||
        die "container '$CONTAINER' not found (set MOONLIGHTWEB_CONTAINER)"
}

backup() {
    need_container
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" = "true" ] ||
        die "container '$CONTAINER' is not running; start it (or restore instead)"

    umask 077
    mkdir -p "$BACKUP_DIR"
    _ts=$(date +%Y%m%d_%H%M%S)
    _file="$BACKUP_DIR/moonlightweb-$_ts.tar.gz"

    say "Backing up /data from '$CONTAINER'..."
    # tar to stdout, not to a file inside the container: the root filesystem is
    # read-only, and /data has no spare room to promise.
    docker exec "$CONTAINER" tar -czf - -C /data . > "$_file" ||
        die "tar failed; $_file is incomplete and should be deleted"

    # Verify the archive is readable and actually contains the state file. An
    # empty or truncated tar is the failure mode worth catching here.
    if ! tar -tzf "$_file" 2>/dev/null |
         grep -q '^\./\.local/share/MoonlightWeb/MoonlightWeb/settings.json$'; then
        rm -f "$_file"
        die "archive did not contain settings.json; backup discarded"
    fi

    _size=$(wc -c < "$_file")
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$_file" > "$_file.sha256"
    fi

    chmod 600 "$_file" 2>/dev/null || true

    say "Wrote $_file ($((_size / 1024)) KiB)"
    say "  contains settings.json, cert/, logs/ and the QSettings identity"
    say "  keep it private: it can impersonate this server on the LAN"

    _cutoff=$((RETENTION_DAYS * 24))
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'moonlightweb-*.tar.gz' \
        -mmin +"$_cutoff" -print -delete 2>/dev/null |
        sed 's/^/  pruned /' || true
}

list_backups() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        say "No backups in $BACKUP_DIR"
        return 0
    fi
    ls -lh "$BACKUP_DIR"/moonlightweb-*.tar.gz 2>/dev/null || say "No backups in $BACKUP_DIR"
}

# Resolve what backs /data so the restore helper can mount the same thing even
# with the application container stopped.
data_mount() {
    _name=$(docker inspect -f \
        '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' \
        "$CONTAINER" 2>/dev/null || true)
    if [ -n "$_name" ]; then
        printf '%s' "$_name"
        return 0
    fi
    docker inspect -f \
        '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' \
        "$CONTAINER" 2>/dev/null
}

restore() {
    _archive=$1
    _assume_yes=${2:-no}

    [ -f "$_archive" ] || die "no such archive: $_archive"
    tar -tzf "$_archive" > /dev/null 2>&1 || die "$_archive is not a readable .tar.gz"
    need_container

    _target=$(data_mount)
    [ -n "$_target" ] || die "could not resolve the /data mount of '$CONTAINER'"

    say "Restoring $_archive"
    say "  into   : $_target"
    say "  replaces: settings.json, cert/, logs/ and the QSettings identity"
    if [ "$_assume_yes" != "yes" ]; then
        printf 'This overwrites the current state. Type "restore" to continue: '
        read -r _answer
        [ "$_answer" = "restore" ] || die "aborted"
    fi

    _user=$(docker inspect -f '{{.Config.User}}' "$APP_IMAGE" 2>/dev/null || true)
    [ -n "$_user" ] || die "image '$APP_IMAGE' not found (set MOONLIGHTWEB_IMAGE)"

    say "Stopping '$CONTAINER'..."
    docker stop "$CONTAINER" > /dev/null

    # The archive is fed on stdin rather than bind-mounted: the Docker daemon
    # resolves -v source paths on the *host*, which is not where this script's
    # relative path lives when the script itself runs in a container.
    #
    # The helper runs as root and chowns the tree to the image's user at the
    # end. Extracting as the image user would be tidier but fails as soon as the
    # volume was written by an image whose uid differs (a rebuild that changed
    # the allocation, or a backup taken before the uid was pinned); root plus an
    # explicit chown makes the restore work either way. The image pins
    # uid/gid 10001:10001 for the application itself.
    say "Extracting (temporary root helper, then chown to '$_user')..."
    docker run --rm -i --network none --user 0 --entrypoint sh \
        -v "$_target:/data" \
        "$APP_IMAGE" -c \
        'find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; tar -xzf - -C /data; chown -R moonlightweb:moonlightweb /data' \
        < "$_archive"

    # The server's singleton lock names a PID from the previous boot; a stale
    # one is harmless in the container (the entrypoint clears it) but removing
    # it here keeps a restore to a bind mount clean as well.
    docker run --rm --network none --user "$_user" --entrypoint sh \
        -v "$_target:/data" \
        "$APP_IMAGE" -c 'rm -f /data/.local/share/MoonlightWeb/MoonlightWeb/moonlightweb.lock' \
        2>/dev/null || true

    say "Starting '$CONTAINER'..."
    docker start "$CONTAINER" > /dev/null

    say "Restored. Verify with:"
    say "  docker exec $CONTAINER moonlightweb --status"
    say "  docker exec $CONTAINER cat /data/.local/share/MoonlightWeb/MoonlightWeb/security.log"
}

case "${1:-}" in
    ''|backup)
        backup
        ;;
    --list|-l)
        list_backups
        ;;
    --restore)
        [ -n "${2:-}" ] || die "usage: $0 --restore <archive> [--yes]"
        _yes=no
        [ "${3:-}" = "--yes" ] && _yes=yes
        restore "$2" "$_yes"
        ;;
    --help|-h)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "unknown argument '$1' (try --help)"
        ;;
esac
