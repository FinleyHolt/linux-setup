#!/usr/bin/env bash
# Laptop networking for NPS HPC: bring up / heal the GlobalProtect VPN, set a
# safe tunnel MTU, and lay the HPC SSH service tunnels. Self-contained laptop
# infra -- no dependency on any project repo, so `vpn` works regardless of
# which DroneProjects-* worktree/branch happens to be checked out.
#
# Subcommands:
#   up        VPN (if needed) + safe MTU + all service tunnels   [default]
#   vpn       VPN + split route + safe MTU + SSH health ONLY (no tunnels).
#             This is what project repos delegate to for the VPN step.
#   tunnels   service tunnels only (assume VPN/path already good)
#   status    VPN state + tun0 MTU + real HPC SSH health + per-port state
#   down      tear down the autossh tunnels (NOT the VPN)
#   reconnect force a clean GlobalProtect re-handshake (stale-session fix)
#   heal      loop: reconcile every NET_HEAL_INTERVAL s (default 30)
#   install-autoheal  user crontab entry: unattended reconcile every 2 min
#                     (no root; survives reboot/logout; flock-guarded)
#   remove-autoheal   remove that crontab entry
#
# VPN sudo is non-interactive via /etc/sudoers.d/nps-vpn (see net/sudoers.d/
# nps-vpn in this repo for the one-time install). Full background + every
# failure mode: net/nps-vpn.md.
#
# Env overrides:
#   NET_HPC_HOST      ssh target            (default finleynps@172.20.44.20)
#   NET_FORWARD_PORTS space-separated -L ports (default "8001 8772 8780 8781 8790")
#   NET_AUX_PORTS     extra -L ports        (default "8002 30000 30174")
#   NET_SOCKS_PORT    dynamic -D SOCKS port (default 1080; 0 disables)
#   NET_HEAL_INTERVAL heal-loop seconds     (default 30)
#   NET_TUN_MTU       tun0 MTU after connect (default 1280; see nps-vpn.md)

set -u

NET_HPC_HOST="${NET_HPC_HOST:-finleynps@172.20.44.20}"
NET_HPC_IP="${NET_HPC_HOST##*@}"
read -r -a _FWD <<<"${NET_FORWARD_PORTS:-8001 8772 8780 8781 8790}"
read -r -a _AUX <<<"${NET_AUX_PORTS:-8002 30000 30174}"
NET_SOCKS_PORT="${NET_SOCKS_PORT:-1080}"
NET_HEAL_INTERVAL="${NET_HEAL_INTERVAL:-30}"
# Tunnel MTU. GlobalProtect brings tun0 up at 1422, too high for many real
# underlays (residential / CGNAT / PPPoE): the TCP handshake succeeds but
# large packets -- e.g. SSH's KEX_ECDH_REPLY -- get black-holed and ssh
# stalls forever. 1280 (the IPv6 minimum) has ample headroom on any path.
# gpclient 2.5.x exposes no --mtu, so we set it on tun0 post-connect.
NET_TUN_MTU="${NET_TUN_MTU:-1280}"
_ALL_PORTS=("${_FWD[@]}" "${_AUX[@]}")

_log() { printf '  %s\n' "$*" >&2; }

# A local port is "ours" when the process listening on it is an ssh / autossh
# whose argv targets the HPC host. Used for idempotency: an already-tunnelled
# port is adopted, never rebound.
_port_owned_by_hpc_tunnel() {
	local p="$1" pid
	for pid in $(ss -tlnpH "sport = :${p}" 2>/dev/null |
		grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
		ps -o args= -p "$pid" 2>/dev/null | grep -q "${NET_HPC_HOST}" && return 0
	done
	return 1
}

_port_bound() { ss -tln 2>/dev/null | grep -q ":${1} "; }

_hpc_direct() {
	# On-campus: HPC:22 reachable without the VPN.
	timeout 3 bash -c "exec 3<>/dev/tcp/${NET_HPC_IP}/22" >/dev/null 2>&1
}

_tun0_up() { ip link show tun0 >/dev/null 2>&1; }

_split_route_present() {
	ip route show 172.20.0.0/16 2>/dev/null | grep -q 'dev tun0'
}

# Lower tun0's MTU so SSH's large key-exchange reply (and any other big frames)
# fit the real path MTU through GlobalProtect over an arbitrary underlay.
# Without it the TCP handshake succeeds but ssh stalls forever at
# SSH2_MSG_KEX_ECDH_REPLY -- a path-MTU black hole. Idempotent; no-op when tun0
# is down or already at NET_TUN_MTU. NOPASSWD via sudoers.d/nps-vpn.
_set_tun_mtu() {
	_tun0_up || return 0
	local cur
	cur="$(cat /sys/class/net/tun0/mtu 2>/dev/null)"
	[ "${cur}" = "${NET_TUN_MTU}" ] && return 0
	if sudo -n /usr/bin/ip link set tun0 mtu "${NET_TUN_MTU}" 2>/dev/null; then
		_log "VPN: tun0 MTU ${cur:-?} -> ${NET_TUN_MTU} (path-MTU safety)."
	else
		_log "VPN: WARNING could not set tun0 MTU=${NET_TUN_MTU}."
		_log "     Install net/sudoers.d/nps-vpn (see net/nps-vpn.md)."
	fi
}

# Real end-to-end HPC health. A TCP connect to :22 is NOT enough -- an MTU
# black hole lets TCP connect while the SSH key exchange stalls -- so this runs
# an actual non-interactive ssh and a hung handshake reads as DOWN.
_hpc_ssh_ok() {
	timeout 14 ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none \
		-o StrictHostKeyChecking=accept-new "${NET_HPC_HOST}" true 2>/dev/null
}

ensure_vpn() {
	# Genuinely on-campus only when HPC is reachable AND there is no tunnel.
	# A lingering-but-dead tun0 (e.g. after switching networks) also makes
	# HPC:22 "reachable" via its route, which used to mask a stale session.
	if _hpc_direct && ! _tun0_up; then
		_log "VPN: on-campus path (HPC:22 direct) -- VPN not needed."
		return 0
	fi
	if _tun0_up; then
		if ! _split_route_present; then
			_log "VPN: tun0 up but split route missing -- re-adding."
			sudo -n /usr/bin/ip route del default dev tun0 2>/dev/null || true
			sudo -n /usr/bin/ip route add 172.20.0.0/16 dev tun0 2>/dev/null || true
		else
			_log "VPN: tun0 up, split route present."
		fi
		_set_tun_mtu
		if _hpc_ssh_ok; then
			_log "VPN: tun0 up, HPC SSH reachable."
		else
			_log "VPN: WARNING tun0 up but HPC SSH not responding -- stale session."
			_log "     Recover with:  nps-vpn.sh reconnect   (alias: vpn-reconnect)"
		fi
		return 0
	fi
	# An earlier connect may still be mid-auth (SAML); never stack a second
	# gpclient on top of it -- just wait on the one in flight.
	if pgrep -f '/usr/bin/gpclient .*connect vpn\.nps\.edu' >/dev/null 2>&1; then
		_log "VPN: a gpclient connect is already in flight -- waiting on it."
	else
		_log "VPN: bringing up GlobalProtect (vpn.nps.edu)."
		# --cookie-cache persists the portal auth cookie across sessions, so
		# reconnects need no SAML until the server expires it. Needs the
		# matching sudoers entry; probe and fall back to the bare command so
		# an older installed sudoers still connects.
		local -a _connect=(/usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache)
		if ! sudo -n -l "${_connect[@]}" >/dev/null 2>&1; then
			_connect=(/usr/bin/gpclient --fix-openssl connect vpn.nps.edu)
		fi
		# setsid -> the VPN client lives in its own session, so it survives
		# this script (and any shell that triggered the heal) exiting.
		setsid sudo -n "${_connect[@]}" >/dev/null 2>&1 &
	fi
	local _i
	for _i in $(seq 1 30); do
		_tun0_up && break
		sleep 1
	done
	if ! _tun0_up; then
		_log "VPN: WARNING tun0 did not appear."
		_log "     - sudo prompted? install net/sudoers.d/nps-vpn (one-time; see net/nps-vpn.md)."
		_log "     - SAML cookie expired on a headless box? run:"
		_log "         sudo /usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache --browser remote"
		_log "       then open the printed URL through an ssh -L forward (nps-vpn.md, 'Headless SAML')."
		return 1
	fi
	sudo -n /usr/bin/ip route del default dev tun0 2>/dev/null || true
	sudo -n /usr/bin/ip route add 172.20.0.0/16 dev tun0 2>/dev/null || true
	_log "VPN: split tunnel active (172.20.0.0/16 via tun0)."
	_set_tun_mtu
	if _hpc_ssh_ok; then
		_log "VPN: HPC SSH reachable."
	else
		_log "VPN: WARNING connected but HPC SSH still failing. If this is a"
		_log "     constrained network, retry lower:  NET_TUN_MTU=1200 nps-vpn.sh up"
	fi
}

# PIDs of forwarding tunnels to the HPC (autossh wrappers OR bare ssh -L/-D).
# An argv must carry both the host and a -L/-D forward to qualify, so an
# interactive `ssh HOST` shell is never matched.
_tunnel_pids() {
	local pid args
	for pid in $(pgrep -f "${NET_HPC_HOST}" 2>/dev/null); do
		kill -0 "$pid" 2>/dev/null || continue
		args="$(ps -o args= -p "$pid" 2>/dev/null)"
		case "$args" in
		*"${NET_HPC_HOST}"*) ;;
		*) continue ;;
		esac
		case "$args" in
		*autossh* | *" -L "* | *" -D "*) echo "$pid" ;;
		esac
	done
}

# Reap forwarding tunnels to the HPC whose every forwarded port went silent --
# a wedged autossh OR a stale `ssh -fN`. Targeted kill by validated PID --
# never `pkill -f` (that self-matches the caller / cross-kills tenants).
_reap_dead_tunnels() {
	local pid any p
	for pid in $(_tunnel_pids); do
		any=0
		for p in "${_ALL_PORTS[@]}" "${NET_SOCKS_PORT}"; do
			[ "$p" = 0 ] && continue
			_port_owned_by_hpc_tunnel "$p" && {
				any=1
				break
			}
		done
		[ "$any" = 0 ] && {
			_log "tunnels: reaping dead tunnel pid ${pid}"
			kill "$pid" 2>/dev/null || true
		}
	done
}

ensure_tunnels() {
	# Re-assert the safe MTU here too: this is the path the per-shell auto-heal
	# takes, so a GP auto-reconnect that reset tun0 to 1422 gets corrected
	# without a full `up`. No-op when tun0 is down (on-campus).
	_set_tun_mtu
	_reap_dead_tunnels
	local fwd=() p
	for p in "${_ALL_PORTS[@]}"; do
		if _port_owned_by_hpc_tunnel "$p"; then
			_log "port ${p}: already tunnelled (skip)"
		elif _port_bound "$p"; then
			_log "port ${p}: bound by another process -- refusing to forward"
		else
			fwd+=(-L "${p}:localhost:${p}")
		fi
	done
	if [ "${NET_SOCKS_PORT}" != 0 ]; then
		if _port_owned_by_hpc_tunnel "${NET_SOCKS_PORT}"; then
			_log "port ${NET_SOCKS_PORT} (SOCKS): already tunnelled (skip)"
		elif _port_bound "${NET_SOCKS_PORT}"; then
			_log "port ${NET_SOCKS_PORT} (SOCKS): bound by another process -- skip"
		else
			fwd+=(-D "127.0.0.1:${NET_SOCKS_PORT}")
		fi
	fi
	if [ "${#fwd[@]}" -eq 0 ]; then
		_log "tunnels: all ports already tunnelled."
		return 0
	fi
	# setsid -> own session, so a SIGTERM to the launching shell process group
	# can never reap this tunnel. autossh -M 0 -f -N -> self-healing, no remote
	# command, backgrounds after auth. ExitOnForwardFailure so a half-open
	# tunnel dies and autossh respawns it clean.
	if AUTOSSH_GATETIME=0 setsid autossh -M 0 -f -N \
		-o ExitOnForwardFailure=yes \
		-o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
		-o StrictHostKeyChecking=accept-new \
		"${fwd[@]}" "${NET_HPC_HOST}"; then
		_log "tunnels: autossh up (${fwd[*]})"
	else
		_log "tunnels: WARNING autossh failed to start (HPC unreachable?)"
		return 1
	fi
}

cmd_status() {
	if _hpc_direct && ! _tun0_up; then
		echo "VPN:        not needed (HPC:22 reachable direct)"
	elif _tun0_up; then
		echo "VPN:        tun0 UP (mtu $(cat /sys/class/net/tun0/mtu 2>/dev/null)), split route $(_split_route_present &&
			echo present || echo MISSING)"
		echo "HPC SSH:    $(_hpc_ssh_ok && echo 'OK (key exchange completes)' ||
			echo 'FAIL -- path/MTU/stale; try: nps-vpn.sh reconnect')"
	else
		echo "VPN:        DOWN (no tun0, HPC not direct)"
	fi
	local p
	for p in "${_ALL_PORTS[@]}"; do
		if _port_owned_by_hpc_tunnel "$p"; then
			echo "port ${p}:   tunnelled -> HPC"
		elif _port_bound "$p"; then
			echo "port ${p}:   bound by NON-tunnel process"
		else
			echo "port ${p}:   down"
		fi
	done
	if [ "${NET_SOCKS_PORT}" != 0 ]; then
		_port_owned_by_hpc_tunnel "${NET_SOCKS_PORT}" &&
			echo "SOCKS ${NET_SOCKS_PORT}: tunnelled -> HPC" ||
			echo "SOCKS ${NET_SOCKS_PORT}: down"
	fi
}

cmd_down() {
	# Tear down only the forwarding tunnels. Leaves the VPN alone.
	local pid killed=0
	for pid in $(_tunnel_pids); do
		kill "$pid" 2>/dev/null && killed=$((killed + 1))
	done
	_log "tunnels: stopped ${killed} tunnel process(es)"
}

cmd_reconnect() {
	# Force a clean GlobalProtect re-handshake. Use when tun0 is up but dead
	# (e.g. you joined a new Wi-Fi and the old session went stale): plain `up`
	# sees the lingering interface and won't re-auth. Tear the session down,
	# wait for tun0 to drop, then run the normal up (reconnect + route + MTU).
	_log "reconnect: disconnecting GlobalProtect."
	sudo -n /usr/bin/gpclient disconnect 2>/dev/null || true
	local _i
	for _i in $(seq 1 15); do _tun0_up || break; sleep 1; done
	_tun0_up && _log "reconnect: WARNING tun0 still present after disconnect."
	cmd_up
}

cmd_up() {
	ensure_vpn || _log "up: VPN step reported a problem (continuing to tunnels)"
	ensure_tunnels
}

cmd_heal() {
	_log "heal: reconcile loop every ${NET_HEAL_INTERVAL}s (Ctrl-C to stop)"
	while true; do
		cmd_up >/dev/null 2>&1 || true
		sleep "${NET_HEAL_INTERVAL}"
	done
}

# Unattended self-healing: a user crontab entry reconciles the whole link
# (VPN + split route + MTU + tunnels) every 2 minutes. flock skips a tick
# while the previous one is still running; the log self-truncates. No root
# needed; survives reboots and logouts (cron runs without a session).
_AUTOHEAL_LOG="${HOME}/.local/state/nps-vpn/autoheal.log"
_AUTOHEAL_TAG="# nps-vpn-autoheal"

cmd_autoheal_tick() {
	{
		printf '%s ' "$(date -Is)"
		cmd_up 2>&1 | tr '\n' '|'
		echo
	} >>"$_AUTOHEAL_LOG"
	if [ "$(stat -c%s "$_AUTOHEAL_LOG" 2>/dev/null || echo 0)" -gt 200000 ]; then
		tail -c 100000 "$_AUTOHEAL_LOG" >"${_AUTOHEAL_LOG}.tmp" &&
			mv "${_AUTOHEAL_LOG}.tmp" "$_AUTOHEAL_LOG"
	fi
	return 0
}

cmd_install_autoheal() {
	local self
	self="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
	mkdir -p "$(dirname "$_AUTOHEAL_LOG")"
	local line="*/2 * * * * flock -n /tmp/nps-vpn-autoheal.lock ${self} autoheal-tick ${_AUTOHEAL_TAG}"
	(
		crontab -l 2>/dev/null | grep -vF "${_AUTOHEAL_TAG}"
		echo "$line"
	) | crontab -
	_log "autoheal: installed (user crontab, every 2 min). Log: ${_AUTOHEAL_LOG}"
	_log "autoheal: remove with '$0 remove-autoheal'."
}

cmd_remove_autoheal() {
	(crontab -l 2>/dev/null | grep -vF "${_AUTOHEAL_TAG}") | crontab -
	_log "autoheal: removed."
}

# Sourced -> expose functions, do not dispatch.
# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]:-$0}" != "${0}" ]; then
	return 0 2>/dev/null || true
fi

case "${1:-up}" in
up) cmd_up ;;
vpn) ensure_vpn ;;
tunnels) ensure_tunnels ;;
status) cmd_status ;;
down) cmd_down ;;
reconnect) cmd_reconnect ;;
heal) cmd_heal ;;
autoheal-tick) cmd_autoheal_tick ;;
install-autoheal) cmd_install_autoheal ;;
remove-autoheal) cmd_remove_autoheal ;;
*)
	echo "usage: $0 {up|vpn|tunnels|status|down|reconnect|heal|install-autoheal|remove-autoheal}" >&2
	exit 2
	;;
esac
