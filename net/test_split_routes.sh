#!/usr/bin/env bash
# Guard for NET_SPLIT_ROUTES in net/nps-vpn.sh: every split-tunnel prefix the
# script asserts must have an `ip route add`/`del` pair in
# net/sudoers.d/nps-vpn. The asserts run under `sudo -n ... 2>/dev/null || true`,
# so a prefix present in only one of the two files fails SILENTLY -- the route
# never appears, every name on that subnet still resolves, and ssh to it hangs
# with no error. That is the shape that hid the GB300 for an afternoon.
#
# Static: reads both files, touches no route, needs no VPN and no sudo.
set -u

NET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${NET_DIR}/nps-vpn.sh"
SUDOERS="${NET_DIR}/sudoers.d/nps-vpn"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -r "${SRC}" ] || fail "missing ${SRC}"
[ -r "${SUDOERS}" ] || fail "missing ${SUDOERS}"

# shellcheck source=/dev/null
source "${SRC}"

# Vacuity floor: a derived check that finds nothing passes. Two prefixes are
# live as of 2026-08-26 (campus/hamming + the ai.nps.edu GB300); fewer means the
# array was gutted or the source stopped defining it, not that all is well.
[ "${#NET_SPLIT_ROUTES[@]}" -ge 2 ] ||
	fail "NET_SPLIT_ROUTES has ${#NET_SPLIT_ROUTES[@]} prefix(es); expected >= 2"

# Pin the two by name. A derivation cannot notice the disappearance of the very
# prefix it derives from.
for pinned in 172.20.0.0/16 10.0.248.0/24; do
	printf '%s\n' "${NET_SPLIT_ROUTES[@]}" | grep -qxF "${pinned}" ||
		fail "${pinned} is no longer in NET_SPLIT_ROUTES (campus/hamming and the ai.nps.edu GB300 are both live)"
done

for prefix in "${NET_SPLIT_ROUTES[@]}"; do
	for verb in add del; do
		grep -qF "/usr/bin/ip route ${verb} ${prefix} dev tun0" "${SUDOERS}" ||
			fail "${prefix} is in NET_SPLIT_ROUTES but sudoers.d/nps-vpn has no \`ip route ${verb}\` for it -- the assert would fail silently under sudo -n"
	done
	echo "ok  ${prefix}  (script + sudoers add/del)"
done

# The reverse direction too: a sudoers grant with no prefix behind it is dead
# privilege, and it means someone removed a prefix and left the grant.
while read -r granted; do
	printf '%s\n' "${NET_SPLIT_ROUTES[@]}" | grep -qxF "${granted}" ||
		fail "sudoers grants \`ip route add ${granted} dev tun0\` but no such prefix is in NET_SPLIT_ROUTES -- stale grant"
done < <(grep -oP '(?<=/usr/bin/ip route add )\S+(?= dev tun0)' "${SUDOERS}")

echo "PASS: ${#NET_SPLIT_ROUTES[@]} split prefixes, script and sudoers agree"
