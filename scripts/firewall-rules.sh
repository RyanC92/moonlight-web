#!/bin/sh
# =============================================================================
#  MoonlightWeb host firewall template (Linux iptables).
#
#  READ THIS FIRST
#  This is a template, not a turnkey firewall. It has not been exercised against
#  a live host in this repository's test cycle (the test host runs Windows).
#  Review every rule, set SSH_PORT, and run it in dry-run mode before --apply.
#
#  DESIGN
#  The rules live in a dedicated chain, MW_INPUT, jumped to from INPUT. Applying
#  the script flushes and rebuilds only that chain, so re-running it does not
#  duplicate rules and does not disturb whatever else manages the host firewall.
#
#  The INPUT policy is left alone unless you pass --default-drop. A chain full
#  of ACCEPT rules does nothing while INPUT's policy is ACCEPT; it becomes a
#  firewall at the moment the policy flips. That switch can lock you out, so it
#  is a separate, explicit flag.
#
#  USAGE
#      ./scripts/firewall-rules.sh                 # print the rules
#      sudo ./scripts/firewall-rules.sh --apply    # install them (asks first)
#      sudo ./scripts/firewall-rules.sh --apply --default-drop
#      sudo ./scripts/firewall-rules.sh --remove
#
#  ENVIRONMENT
#      SSH_PORT        SSH port to keep open              (default 22)
#      MW_HTTP_PORT    plain HTTP listener                (default 8080)
#      MW_HTTPS_PORT   HTTPS listener                     (default 8443)
#      ALLOW_MDNS      UDP 5353 for LAN discovery         (default 1)
#      ALLOW_UPNP      UDP 47999 for Internet Access UPnP (default 0; LAN-only)
#      ALLOW_STUN      UDP 3478 outbound STUN             (default 0; LAN-only)
#
#  Persistence: iptables rules are not saved. Use netfilter-persistent
#  (`iptables-save > /etc/iptables/rules.v4`) or your distribution's mechanism.
# =============================================================================
set -eu

CHAIN=MW_INPUT
SSH_PORT="${SSH_PORT:-22}"
HTTP_PORT="${MW_HTTP_PORT:-8080}"
HTTPS_PORT="${MW_HTTPS_PORT:-8443}"
ALLOW_MDNS="${ALLOW_MDNS:-1}"
ALLOW_UPNP="${ALLOW_UPNP:-0}"
ALLOW_STUN="${ALLOW_STUN:-0}"

MODE=dry-run
DEFAULT_DROP=no
ASSUME_YES=no

for arg in "$@"; do
    case "$arg" in
        --apply)        MODE=apply ;;
        --remove)       MODE=remove ;;
        --default-drop) DEFAULT_DROP=yes ;;
        --yes|-y)       ASSUME_YES=yes ;;
        --help|-h)
            sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'unknown argument: %s (try --help)\n' "$arg" >&2
            exit 2
            ;;
    esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Rules are appended to MW_INPUT in this order. Kept in a function so dry-run
# and apply print and use exactly the same list.
rules() {
    echo "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
    echo "-i lo -j ACCEPT"
    echo "-p tcp --dport $SSH_PORT -j ACCEPT"
    echo "-p tcp --dport $HTTPS_PORT -j ACCEPT"
    echo "-p tcp --dport $HTTP_PORT -j ACCEPT"
    echo "-p udp --dport 48550:48573 -j ACCEPT"
    [ "$ALLOW_MDNS" = "1" ] && echo "-p udp --dport 5353 -j ACCEPT"
    [ "$ALLOW_UPNP" = "1" ] && echo "-p udp --dport 47999 -j ACCEPT"
    [ "$ALLOW_STUN" = "1" ] && echo "-p udp --dport 3478 -j ACCEPT"
    return 0
}

show() {
    _policy=$(iptables -S INPUT 2>/dev/null | head -1 || true)
    [ -n "$_policy" ] || _policy="(iptables not available here)"
    echo "Chain $CHAIN ($_policy)"
    rules | sed 's/^/  /'
    echo
    echo "Ports: SSH $SSH_PORT/tcp, HTTPS $HTTPS_PORT/tcp, HTTP $HTTP_PORT/tcp,"
    echo "       WebRTC 48550-48573/udp"
    [ "$ALLOW_MDNS" = "1" ] && echo "       mDNS 5353/udp"
    [ "$ALLOW_UPNP" = "1" ] && echo "       UPnP 47999/udp"
    [ "$ALLOW_STUN" = "1" ] && echo "       STUN 3478/udp"
    echo
    echo "Note: WebRTC also opens one ephemeral UDP port per stream slot; the"
    echo "      fixed range above is what the app uses for published media."
}

case "$MODE" in
    dry-run)
        echo "Dry run — nothing is changed. Re-run with --apply to install."
        echo
        show
        echo
        echo "Add --default-drop to make INPUT default to DROP (this is what"
        echo "actually turns the chain into a firewall; it can lock out SSH)."
        ;;
    remove)
        [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 --remove)"
        iptables -D INPUT -j "$CHAIN" 2>/dev/null || true
        iptables -F "$CHAIN" 2>/dev/null || true
        iptables -X "$CHAIN" 2>/dev/null || true
        echo "Removed $CHAIN and its jump from INPUT. INPUT policy is unchanged."
        if [ "$(iptables -S INPUT 2>/dev/null | head -1)" = "-P INPUT DROP" ]; then
            echo "WARNING: INPUT policy is still DROP; set it back with:"
            echo "  iptables -P INPUT ACCEPT"
        fi
        ;;
    apply)
        [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 --apply)"

        show
        echo
        if [ "$DEFAULT_DROP" = "yes" ]; then
            echo "This will set INPUT policy to DROP. Make sure SSH on port"
            echo "$SSH_PORT is reachable before you disconnect."
        else
            echo "INPUT policy will stay as it is. The chain is installed, but"
            echo "without --default-drop it only adds ACCEPT rules."
        fi
        if [ "$ASSUME_YES" != "yes" ]; then
            printf 'Type "apply" to continue: '
            read -r answer
            [ "$answer" = "apply" ] || die "aborted"
        fi

        iptables -N "$CHAIN" 2>/dev/null || true
        iptables -F "$CHAIN"
        rules | while read -r rule; do
            # shellcheck disable=SC2086 -- the rule is a word list by design.
            iptables -A "$CHAIN" $rule
        done
        iptables -C INPUT -j "$CHAIN" 2>/dev/null || iptables -I INPUT 1 -j "$CHAIN"

        if [ "$DEFAULT_DROP" = "yes" ]; then
            iptables -P INPUT DROP
        fi

        echo
        echo "Applied. Verify with: iptables -S $CHAIN; iptables -S INPUT"
        echo "Persist with: iptables-save > /etc/iptables/rules.v4"
        ;;
esac
