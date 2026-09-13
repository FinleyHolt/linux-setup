#!/usr/bin/env bash
# Guard for _wedged_dial_pid in net/nps-vpn.sh: an "in flight" gpclient older
# than NET_DIAL_WEDGED_AFTER is wedged on an invisible SAML webview, not
# mid-auth, and ensure_vpn must stop loud instead of waiting on it forever.
# Drives the predicate with decoy argvs -- never gpclient, sudo, or the tunnel.
set -u

SRC="${HOME}/Github/linux-setup/net/nps-vpn.sh"
PIDS=()
trap 'for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# decoy <varname> <argv> -- a process whose full cmdline is <argv>, alive long
# enough for the checks. Assigns rather than echoes: a $( ) subshell would hand
# the child the substitution pipe and the pid would not be ours to track.
decoy() {
	bash -c 'exec -a "$1" sleep 30' _ "$2" >/dev/null 2>&1 &
	printf -v "$1" '%s' "$!"
	PIDS+=("$!")
}

# shellcheck source=/dev/null
source "${SRC}"

DIAL="/usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache --reconnect-timeout 1200"
decoy PID_WEDGED "${DIAL}"
decoy PID_HUMAN "${DIAL} --browser remote"
decoy PID_SHELL "/usr/bin/zsh -c echo ${DIAL}"
sleep 2 # ps etimes is whole seconds; a 0s decoy is not "older than 0"

NET_DIAL_WEDGED_AFTER=0
GOT="$(_wedged_dial_pid)" || fail "a stale headless dial was not reported wedged"
[ "${GOT}" = "${PID_WEDGED}" ] || fail "reported pid ${GOT}, expected ${PID_WEDGED}"
echo "PASS: stale headless dial (pid ${PID_WEDGED}) reads as wedged"

# With the only wedged candidate gone, the survivors must all be rejected --
# including the real gpclient holding the live tunnel, which carries
# --browser remote and would otherwise read as a wedge on every healthy box.
kill "${PID_WEDGED}" 2>/dev/null
sleep 1
if GOT="$(_wedged_dial_pid)"; then
	case "$(ps -o args= -p "${GOT}" 2>/dev/null)" in
	*'--browser remote'*) fail "a --browser remote login read as wedged (pid ${GOT})" ;;
	*zsh*) fail "a shell merely mentioning gpclient read as wedged (anchor lost)" ;;
	*) fail "unexpected pid ${GOT} read as wedged" ;;
	esac
fi
echo "PASS: --browser remote dial (pid ${PID_HUMAN}) is never wedged"
echo "PASS: shell argv mentioning gpclient (pid ${PID_SHELL}) does not match"

# The threshold is the whole point: a fresh dial is mid-auth, not wedged.
decoy PID_FRESH "${DIAL}"
sleep 1
NET_DIAL_WEDGED_AFTER=300
! _wedged_dial_pid >/dev/null || fail "a seconds-old dial read as wedged at a 300s threshold"
echo "PASS: fresh dial (pid ${PID_FRESH}) waits, not wedged, under the default threshold"

# _saml_reauth_needed stands down while a --browser remote login is in flight.
# Its pgrep must be anchored the same way: a shell merely MENTIONING such a
# dial suppressed the cookie-expired marker for twenty ticks once, each of
# them a SAML launch at the portal. Assert on the pattern itself: on a box
# with a live tunnel the real gpclient (which carries --browser remote) is
# always matched too, so the predicate cannot be driven end to end here.
decoy PID_SHELL_HUMAN "/usr/bin/zsh -c echo ${DIAL} --browser remote"
sleep 1
PAT="$(grep -oE "pgrep -f '[^']*--browser remote'" "${SRC}" | head -1 | sed "s/^pgrep -f '//; s/'\$//")"
[ -n "${PAT}" ] || fail "could not find the --browser remote pgrep in ${SRC}"
MATCHED=" $(pgrep -f "${PAT}" 2>/dev/null | tr '\n' ' ') "
case "${MATCHED}" in
*" ${PID_HUMAN} "*) ;;
*) fail "a real --browser remote dial (pid ${PID_HUMAN}) is not matched by '${PAT}'" ;;
esac
case "${MATCHED}" in
*" ${PID_SHELL_HUMAN} "*) fail "a shell mentioning the dial (pid ${PID_SHELL_HUMAN}) is matched by '${PAT}' (anchor lost)" ;;
esac
echo "PASS: the login-in-flight pgrep matches the dial and not a shell that mentions it"
