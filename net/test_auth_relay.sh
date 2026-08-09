#!/usr/bin/env bash
# Guard for the SAML-round relay in net/nps-vpn.sh: gpauth binds its auth server
# to the LAN address on an ephemeral port, and _auth_relay_up must republish that
# exact socket on the tailnet address at NET_AUTH_RELAY_PORT. Stands a throwaway
# HTTP server in for gpauth so the test never touches a real single-use auth URL.
set -u

SRC="${HOME}/Github/linux-setup/net/nps-vpn.sh"
LAN_IP="$(hostname -I | tr ' ' '\n' | grep -E '^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[01])\.' | head -1)"
SRV_PORT=45671
WORK="$(mktemp -d)"
trap 'kill "${SRV_PID:-0}" 2>/dev/null; rm -rf "${WORK}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -n "${LAN_IP}" ] || fail "no LAN address to stand in for gpauth's bind"
echo "marker-ok" >"${WORK}/marker.txt"
( cd "${WORK}" && exec python3 -m http.server "${SRV_PORT}" --bind "${LAN_IP}" ) >/dev/null 2>&1 &
SRV_PID=$!
sleep 1
kill -0 "${SRV_PID}" 2>/dev/null || fail "stand-in server did not start on ${LAN_IP}:${SRV_PORT}"

# shellcheck source=/dev/null
source "${SRC}"

TS="$(_tailnet_ip)"
[ -n "${TS}" ] || fail "_tailnet_ip empty -- tailscaled down?"

PUB="$(_auth_relay_up "${LAN_IP}" "${SRV_PORT}")"
[ -n "${PUB}" ] || fail "_auth_relay_up produced no host:port"
[ "${PUB}" = "${TS}:${NET_AUTH_RELAY_PORT}" ] || fail "published '${PUB}', expected '${TS}:${NET_AUTH_RELAY_PORT}'"

BODY="$(python3 -c "
import sys, urllib.request
print(urllib.request.urlopen('http://${PUB}/marker.txt', timeout=8).read().decode().strip())
" 2>&1)"
[ "${BODY}" = "marker-ok" ] || fail "fetch through the relay returned '${BODY}'"
echo "PASS: http://${PUB}/ reaches ${LAN_IP}:${SRV_PORT}"

# The relay must be tailnet-only: nothing bound on the LAN address at that port.
if ss -tln 2>/dev/null | grep -qE "(^|[[:space:]])(0\.0\.0\.0|${LAN_IP}):${NET_AUTH_RELAY_PORT}[[:space:]]"; then
	fail "relay is bound wider than the tailnet address"
fi
echo "PASS: relay bound only on ${TS}"

_auth_relay_down
sleep 0.5
ss -tln 2>/dev/null | grep -q ":${NET_AUTH_RELAY_PORT} " && fail "_auth_relay_down left the port bound"
echo "PASS: _auth_relay_down released :${NET_AUTH_RELAY_PORT}"
