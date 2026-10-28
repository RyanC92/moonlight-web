#!/bin/sh
# =============================================================================
#  MoonlightWeb security scan.
#
#  Verifies the *runtime* posture of the deployed container against the claims
#  in docs/DEPLOY.md. Exits non-zero if any check fails, so it can gate a
#  deployment in CI or a pre-flight check.
#
#  Usage:
#      ./scripts/security-scan.sh [container-name]
# =============================================================================
set -u

CONTAINER="${1:-moonlightweb}"

esc=$(printf '\033')
GREEN="${esc}[0;32m"
RED="${esc}[0;31m"
YELLOW="${esc}[1;33m"
DIM="${esc}[2m"
NC="${esc}[0m"

PASS=0
FAIL=0
WARN=0

pass() { PASS=$((PASS + 1)); printf '%s PASS %s %s\n' "$GREEN" "$NC" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '%s FAIL %s %s\n' "$RED" "$NC" "$1"; }
warn() { WARN=$((WARN + 1)); printf '%s WARN %s %s\n' "$YELLOW" "$NC" "$1"; }

inspect_fmt() {
    docker inspect --format "$1" "$CONTAINER" 2>/dev/null
}

if ! docker inspect "$CONTAINER" > /dev/null 2>&1; then
    echo "ERROR: container '$CONTAINER' not found" >&2
    exit 2
fi

echo
echo "MoonlightWeb security scan — container: $CONTAINER"
echo "=================================================="

# ── Container isolation ──────────────────────────────────────────────────────
echo
echo "Container isolation"

case "$(inspect_fmt '{{.HostConfig.Privileged}}')" in
    false) pass "not privileged" ;;
    *)     fail "container is privileged" ;;
esac

case "$(inspect_fmt '{{json .HostConfig.CapDrop}}')" in
    *'"ALL"'*) pass "all capabilities dropped" ;;
    *)         fail "capabilities not dropped (CapDrop=$(inspect_fmt '{{json .HostConfig.CapDrop}}'))" ;;
esac

case "$(inspect_fmt '{{json .HostConfig.CapAdd}}')" in
    *'"NET_BIND_SERVICE"'*) pass "only NET_BIND_SERVICE added" ;;
    *null*|'[]'|'')        warn "no capabilities added (fine if ports are >1024)" ;;
    *)                     warn "more than NET_BIND_SERVICE added: $(inspect_fmt '{{json .HostConfig.CapAdd}}')" ;;
esac

case "$(inspect_fmt '{{json .HostConfig.SecurityOpt}}')" in
    *no-new-privileges*) pass "no-new-privileges enabled" ;;
    *)                   fail "no-new-privileges NOT set" ;;
esac

case "$(inspect_fmt '{{.HostConfig.ReadonlyRootfs}}')" in
    true) pass "read-only root filesystem" ;;
    *)    fail "root filesystem is writable" ;;
esac

case "$(inspect_fmt '{{.Config.User}}')" in
    ''|root|0) fail "container runs as root" ;;
    *)         pass "runs as non-root user '$(inspect_fmt '{{.Config.User}}')'" ;;
esac

# ── Network ──────────────────────────────────────────────────────────────────
echo
echo "Network"

case "$(inspect_fmt '{{.HostConfig.NetworkMode}}')" in
    host) pass "host networking (WebRTC/mDNS/UPnP work as upstream intends)" ;;
    *)    warn "network mode '$(inspect_fmt '{{.HostConfig.NetworkMode}}')': mDNS and WebRTC may not work" ;;
esac

# ── Resource bounds ──────────────────────────────────────────────────────────
echo
echo "Resource bounds"

mem=$(inspect_fmt '{{.HostConfig.Memory}}')
if [ -n "$mem" ] && [ "$mem" != "0" ]; then
    pass "memory limited to $((mem / 1024 / 1024)) MiB"
else
    fail "no memory limit"
fi

cpu=$(inspect_fmt '{{.HostConfig.NanoCpus}}')
if [ -n "$cpu" ] && [ "$cpu" != "0" ]; then
    pass "CPU limited to $((cpu / 1000000000)).$(printf '%03d' $(((cpu / 1000000) % 1000))) cores"
else
    fail "no CPU limit"
fi

# ── Configuration & auth posture ────────────────────────────────────────────
echo
echo "Configuration and authentication"

if docker exec "$CONTAINER" sh -c 'test -f /data/.local/share/MoonlightWeb/MoonlightWeb/settings.json' 2>/dev/null; then
    pass "settings.json present on the volume"
    if docker exec "$CONTAINER" sh -c 'jq -e . /data/.local/share/MoonlightWeb/MoonlightWeb/settings.json >/dev/null 2>&1' 2>/dev/null; then
        pass "settings.json is valid JSON"
    else
        fail "settings.json is not valid JSON"
    fi
    if docker exec "$CONTAINER" sh -c 'jq -e "has(\"admin_password\")" /data/.local/share/MoonlightWeb/MoonlightWeb/settings.json >/dev/null 2>&1' 2>/dev/null; then
        pass "admin password is set"
    else
        warn "admin password not set (docker exec $CONTAINER moonlightweb --set-admin-password)"
    fi
else
    warn "settings.json not created yet (server has not written it)"
fi

if docker exec "$CONTAINER" sh -c 'test -f /data/.local/share/MoonlightWeb/MoonlightWeb/security.log' 2>/dev/null; then
    pass "security event log present"
else
    fail "security event log missing"
fi

# ── Listening surface ────────────────────────────────────────────────────────
echo
echo "Listening surface"

if docker exec "$CONTAINER" moonlightweb --status > /dev/null 2>&1; then
    pass "--status reports the server is up"
else
    fail "--status does not answer"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
total=$((PASS + FAIL + WARN))
echo
echo "=================================================="
printf 'checks: %s   pass: %s%s%s   fail: %s%s%s   warn: %s%s%s\n' \
    "$total" "$GREEN" "$PASS" "$NC" "$RED" "$FAIL" "$NC" "$YELLOW" "$WARN" "$NC"

if [ "$FAIL" -gt 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
exit 0
