#!/usr/bin/env bash
# Guard for the dial backoff in net/nps-vpn.sh: a dial that leaves no tun0
# doubles the wait before the next unattended one, capped at an hour, and any
# success clears it. Runs against a throwaway state dir; touches no network,
# no sudo, no crontab.
set -u

SRC="${HOME}/Github/linux-setup/net/nps-vpn.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=/dev/null
source "${SRC}"
_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "${_STATE_DIR}"' EXIT
_CONNECT_LOG="${_STATE_DIR}/last_connect.log"

_dial_due || fail "a fresh state dir must allow a dial"
echo "PASS: no history, dial allowed"

now="$(date +%s)"
expect=(120 240 480 960 1920 3600 3600)
for i in "${!expect[@]}"; do
	_dial_failed
	next="$(cat "${_STATE_DIR}/next_dial")"
	wait=$(( next - now ))
	want="${expect[$i]}"
	# _dial_failed reads the clock itself; allow the seconds this loop took.
	[ "$wait" -ge "$want" ] && [ "$wait" -le $(( want + 5 )) ] ||
		fail "after $((i + 1)) failure(s) the wait is ${wait}s, expected ${want}s"
	_dial_due 2>/dev/null && fail "a dial was allowed inside the backoff window"
done
echo "PASS: waits double 2->32 min and cap at 60 min; the window refuses a dial"
[ "$(cat "${_STATE_DIR}/dial_fails")" = "${#expect[@]}" ] || fail "failure count did not track"

# An elapsed window allows the dial again without clearing the count.
echo $(( now - 1 )) >"${_STATE_DIR}/next_dial"
_dial_due || fail "an elapsed window must allow a dial"
echo "PASS: an elapsed window allows the next dial"

touch "${_STATE_DIR}/cookie_expired"
_dial_ok
for f in dial_fails next_dial cookie_expired; do
	[ -e "${_STATE_DIR}/$f" ] && fail "_dial_ok left $f behind"
done
echo "PASS: a success clears the count, the window and the cookie marker"

# The evidence trail: the previous dial's log is archived under a header.
# (_saml_reauth_needed itself is not driven here: on a box with a live tunnel
# the real gpclient carries --browser remote and suppresses it by design;
# net/test_stale_dial.sh pins the anchor that decides that.)
printf 'SAML auth launch: gateway=false\n' >"${_CONNECT_LOG}"
_archive_dial_log
grep -q '^== ' "${_STATE_DIR}/dials.log" || fail "dials.log has no header"
grep -q 'SAML auth launch' "${_STATE_DIR}/dials.log" || fail "dials.log lost the dial's output"
echo "PASS: a dial's output is archived under a stamped header"

# The dial cascade reads the NOPASSWD listing, never `sudo -l <command>`
# (which says yes to anything the sudo group may run with a password).
_sudo_grants "/usr/bin/gpclient --bogus never granted" && fail "_sudo_grants said yes to a vector no sudoers file carries"
echo "PASS: an ungranted vector reads as ungranted"
