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
#   reconnect re-assert route/MTU/DNS/tunnels (NO logout); --force to drop+re-login
#   login     interactive re-auth (headless SAML) after SSO-cookie expiry;
#             prints an ssh -L line + stamps the cookie mint for lifetime stats
#   cookie    show SSO-cookie age + measured lifetime(s)
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
# GlobalProtect/openconnect silently restores a DROPPED tunnel to the SAME 30-day
# session (no SAML, no phone MFA) as long as the underlay returns within this
# window. The default is 300s (5 min); a flaky USB WiFi dongle is often out longer
# than that, and once openconnect gives up the session is gone -> full interactive
# SAML + Authenticator push. Widen it so multi-minute dongle outages are ridden
# out silently -- this is the main lever for "fewer logins". 4 digits (the sudoers
# glob bounds it to [0-9][0-9][0-9][0-9]); env-overridable.
NET_RECONNECT_TIMEOUT="${NET_RECONNECT_TIMEOUT:-1200}"
_ALL_PORTS=("${_FWD[@]}" "${_AUX[@]}")

# --- Cookie-lifetime + expiry state -------------------------------------------
# When the SSO cookie expires the autoheal drops ${_STATE_DIR}/cookie_expired
# (it can't self-heal that -- only an interactive `vpn login` can). An
# interactive-shell hook in zshrc reads that marker and warns at the prompt, so
# a dead VPN meets you at the terminal -- no push service, no extra app.
_STATE_DIR="${HOME}/.local/state/nps-vpn"
_MINT_FILE="${_STATE_DIR}/cookie_minted"       # epoch of last interactive SAML
_CONNECT_LOG="${_STATE_DIR}/last_connect.log"  # output of the last headless dial

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
		# Once the SSO cookie is known-expired, a headless --cookie-cache dial only
		# jumps to the embedded browser and panics -- it CANNOT recover here. Stop
		# dialing (no sudo spam every 2 min) and point at the one thing that works.
		# The marker is cleared by a successful `vpn login` / tun0 coming up.
		if [ -f "${_STATE_DIR}/cookie_expired" ]; then
			_log "VPN: SSO cookie expired -- automated reconnect can't help (NPS needs"
			_log "     an interactive login). Recover with:  vpn login   (on finley-ub-dt)."
			return 1
		fi
		_log "VPN: bringing up GlobalProtect (vpn.nps.edu)."
		# --cookie-cache persists the portal auth cookie across sessions, so
		# reconnects need no SAML until the server expires it. Needs the
		# matching sudoers entry; probe and fall back to the bare command so
		# an older installed sudoers still connects.
		local -a _connect=(/usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache --reconnect-timeout "${NET_RECONNECT_TIMEOUT}")
		if ! sudo -n -l "${_connect[@]}" >/dev/null 2>&1; then
			_connect=(/usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache)
			if ! sudo -n -l "${_connect[@]}" >/dev/null 2>&1; then
				_connect=(/usr/bin/gpclient --fix-openssl connect vpn.nps.edu)
			fi
		fi
		# setsid -> the VPN client lives in its own session, so it survives
		# this script (and any shell that triggered the heal) exiting.
		mkdir -p "${_STATE_DIR}" 2>/dev/null || true
		setsid sudo -n "${_connect[@]}" >"${_CONNECT_LOG}" 2>&1 &
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

# GlobalProtect resets tun0's DNS to NPS with a catch-all (~.) routing domain on
# every connect, so ALL name lookups tunnel through NPS -- slow, a privacy leak,
# and concurrent public lookups (several Claude Code chats) fail when the tunnel
# hiccups. Restrict tun0 to *.nps.edu; everything else resolves off the VPN.
# Idempotent (only acts when ~. is present); re-applied on every reconcile.
# Needs the resolvectl NOPASSWD sudoers entry.
_ensure_split_dns() {
	_tun0_up || return 0
	command -v resolvectl >/dev/null 2>&1 || return 0
	resolvectl status tun0 2>/dev/null | grep -q 'DNS Domain:.*~\.' || return 0
	if sudo -n /usr/bin/resolvectl domain tun0 '~nps.edu' 2>/dev/null; then
		_log "VPN: split-DNS applied (tun0 -> ~nps.edu; public DNS stays off-VPN)."
	else
		_log "VPN: WARNING split-DNS not applied -- re-install sudoers.d/nps-vpn (adds resolvectl)."
	fi
}

ensure_tunnels() {
	# Re-assert the safe MTU here too: this is the path the per-shell auto-heal
	# takes, so a GP auto-reconnect that reset tun0 to 1422 gets corrected
	# without a full `up`. No-op when tun0 is down (on-campus).
	_set_tun_mtu
	_ensure_split_dns
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
	# SAFETY: on NPS, `gpclient disconnect` LOGS OUT the 30-day session and there
	# is no silent cookie reconnect (--cookie-cache jumps to an embedded browser
	# that can't run on a headless box), so a blind disconnect strands you at a
	# full interactive re-login. Default behaviour therefore NEVER disconnects --
	# it re-asserts split route + MTU + DNS + tunnels, which fixes the common
	# "network changed / tun0 stale" case. Use `reconnect --force` only when you
	# accept that a `vpn login` will be needed afterwards.
	if [ "${1:-}" = "--force" ]; then
		_log "reconnect: --force -- disconnecting. This LOGS OUT the NPS session;"
		_log "           you WILL need a full 'vpn login' afterwards."
		sudo -n /usr/bin/gpclient disconnect 2>/dev/null || true
		local _i
		for _i in $(seq 1 15); do _tun0_up || break; sleep 1; done
		cmd_up
		return
	fi
	if ! _tun0_up; then
		_log "reconnect: VPN is down -- NPS needs an interactive login to recover:"
		_log "             vpn login        (run on finley-ub-dt)"
		ensure_tunnels
		return
	fi
	_log "reconnect: re-asserting split route + MTU + DNS + tunnels (no logout)."
	cmd_up
	if ! _hpc_ssh_ok; then
		_log "reconnect: WARNING tun0 up but HPC SSH still failing -- session looks"
		_log "           dead. NPS can't silently reconnect; recover with:"
		_log "             vpn login                     (full re-login), or"
		_log "             nps-vpn.sh reconnect --force   (drop first, then re-login)"
	fi
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

# Keep GlobalProtect's inactivity timer from firing by pushing a packet through
# tun0 each reconcile. Outbound alone counts -- the gateway resets its idle
# timer on any traffic through the tunnel, reply or not. No-op if tun0 is down.
# (The autossh tunnels already generate traffic when SSH is up; this covers the
# gap when the tunnels are down but the VPN is still up.)
_tunnel_keepalive() {
	_tun0_up || return 0
	ping -c1 -W1 -I tun0 "${NET_HPC_IP}" >/dev/null 2>&1 || true
}

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
	# Detect the one failure autoheal can't fix -- SSO-cookie expiry -- and drop a
	# marker the shell hook warns on. On recovery clear it + send tunnel keepalive.
	if ! _tun0_up && ! _hpc_direct && _saml_reauth_needed; then
		_record_cookie_expiry
	elif _tun0_up; then
		rm -f "${_STATE_DIR}/cookie_expired" 2>/dev/null || true
		_tunnel_keepalive
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

# --- SSO-cookie expiry: detect, measure, nudge --------------------------------

# True when the last headless dial shows a human SAML login is required (cached
# cookie expired): the embedded browser can't start on a headless box ("Failed
# to initialize GTK") and gpclient logs a SAML launch. Suppressed while a
# remote-browser login is already in flight -- a human is handling it.
_saml_reauth_needed() {
	pgrep -f 'gpclient .*--browser remote' >/dev/null 2>&1 && return 1
	[ -r "${_CONNECT_LOG}" ] || return 1
	grep -qiE 'Failed to initialize GTK|SAML auth launch|authentication is required' \
		"${_CONNECT_LOG}" 2>/dev/null
}

# Stamp the first tick of an expiry episode and, if we know when the cookie was
# minted, log how long it lasted -- the empirical SSO-cookie lifetime.
_record_cookie_expiry() {
	local exp="${_STATE_DIR}/cookie_expired"
	[ -f "$exp" ] && return 0
	mkdir -p "${_STATE_DIR}" 2>/dev/null || true
	date +%s >"$exp"
	[ -r "${_MINT_FILE}" ] || return 0
	local mint now life_h
	mint="$(cat "${_MINT_FILE}" 2>/dev/null)"
	[ -n "${mint:-}" ] || return 0
	now="$(date +%s)"
	life_h=$(( (now - mint) / 3600 ))
	printf '%s cookie lasted ~%sh (minted %s)\n' "$(date -Is)" "$life_h" \
		"$(date -d "@${mint}" -Is 2>/dev/null)" >>"${_STATE_DIR}/cookie_lifetime.log"
}

# --- Interactive re-auth: driven from ONE terminal on finley-ub-dt ------------
# `vpn login` (run on finley-ub-dt) walks both NPS SAML rounds with prompts. Per
# round you run ONE `ssh -L` + open a URL on the LAPTOP, finish in the browser,
# then paste the callback back into THIS terminal. No second command, no hidden
# round-2 URL, no machine mix-ups.

_GPAUTH_TMUX="gpauth"

# Push text to this terminal's clipboard via OSC52 (DCS-wrapped inside tmux so it
# survives tmux -> Ghostty). Non-zero if there's no controlling terminal.
_clip_to_terminal() {
	[ -c /dev/tty ] || return 1
	local b64
	b64=$(printf '%s' "$1" | base64 2>/dev/null | tr -d '\n') || return 1
	if [ -n "${TMUX:-}" ]; then
		printf '\033Ptmux;\033\033]52;c;%s\a\033\\' "$b64" >/dev/tty 2>/dev/null
	else
		printf '\033]52;c;%s\a' "$b64" >/dev/tty 2>/dev/null
	fi
}

# Wait (~40s) for a SAML round's auth URL. Echo "IP PORT TOKEN" for a local auth
# server (use ssh -L), or "MS <url>" when only the piped Microsoft URL exists.
# Returns 0 with no output if tun0 comes up meanwhile (round not needed).
_login_round_url() {
	local kind="$1" i url gw port
	for i in $(seq 1 40); do
		_tun0_up && return 0
		url=""
		if [ "$kind" = gateway ]; then
			gw=$(pgrep -f 'gpauth vpn\.nps\.edu --gateway' | head -1)
			if [ -n "$gw" ]; then
				port=$(ss -tlnpH 2>/dev/null | grep "pid=${gw}," | grep -oE ':[0-9]+' | head -1 | tr -d ':')
				if [ -z "$port" ]; then
					url=$(tr '\0' '\n' <"/proc/${gw}/cmdline" 2>/dev/null | grep -m1 '^https://login.microsoftonline.com')
					[ -n "$url" ] && { printf 'MS %s\n' "$url"; return 0; }
				else
					url=$(tmux capture-pane -t "${_GPAUTH_TMUX}" -p -S -60 2>/dev/null | grep -oE "http://[0-9.]+:${port}/[a-f0-9-]+" | tail -1)
				fi
			fi
		else
			url=$(tmux capture-pane -t "${_GPAUTH_TMUX}" -p 2>/dev/null | grep -oE 'http://[0-9.]+:[0-9]+/[a-f0-9-]+' | tail -1)
		fi
		case "$url" in
		http://*)
			local ip pt tok
			ip=${url#http://}; ip=${ip%%:*}
			pt=${url#http://*:}; pt=${pt%%/*}
			tok=${url##*/}
			printf '%s %s %s\n' "$ip" "$pt" "$tok"
			return 0 ;;
		esac
		sleep 1
	done
	return 1
}

# Drive one SAML round: fetch its URL, print LAPTOP instructions, read the
# callback from THIS terminal, inject it into the gpclient pane.
_login_round() {
	local kind="$1" parts cb msurl
	parts=$(_login_round_url "$kind")
	_tun0_up && return 0
	printf '\n' >&2
	# shellcheck disable=SC2086
	set -- $parts
	if [ "${1:-}" = MS ]; then
		msurl="$2"
		_log "-- ${kind} round -- no local URL; using the direct Microsoft URL:"
		if _clip_to_terminal "$msurl"; then
			_log "   -> pushed to your CLIPBOARD; paste it into a browser tab on your laptop."
		else
			_log "   open this on your laptop:"
			printf '  %s\n' "$msurl" >&2
		fi
	elif [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ]; then
		_log "-- ${kind} round -- ON YOUR LAPTOP (one terminal):"
		_log "     ssh -L ${2}:${1}:${2} finley-ub-dt"
		_log "   then open in your browser:  http://localhost:${2}/${3}"
	else
		_log "login: couldn't get the ${kind} URL in time. Inspect: tmux attach -t ${_GPAUTH_TMUX}"
		return 1
	fi
	printf '  Finish it in the browser, then paste the %s globalprotectcallback here + Enter:\n  > ' "$kind" >&2
	IFS= read -r cb || return 1
	[ -z "$cb" ] && { _log "login: no callback entered -- aborting."; return 1; }
	tmux set-buffer -- "$cb"
	tmux paste-buffer -t "${_GPAUTH_TMUX}"
	tmux send-keys -t "${_GPAUTH_TMUX}" Enter
	_log "   ${kind} callback submitted."
}

# Fallback one-shot injector: vpn login --callback '<globalprotectcallback:...>'
# (run on finley-ub-dt while a `vpn login` is already in flight).
_login_callback() {
	{ command -v tmux >/dev/null 2>&1 && tmux has-session -t "${_GPAUTH_TMUX}" 2>/dev/null; } ||
		{ _log "login: no auth in flight -- start it on finley-ub-dt first: vpn login"; return 1; }
	tmux set-buffer -- "$1"
	tmux paste-buffer -t "${_GPAUTH_TMUX}"
	tmux send-keys -t "${_GPAUTH_TMUX}" Enter
	local i
	for i in $(seq 1 60); do
		if _tun0_up; then
			date +%s >"${_MINT_FILE}"; rm -f "${_STATE_DIR}/cookie_expired" 2>/dev/null
			_log "login: connected."; return 0
		fi
		sleep 2
	done
	_log "login: callback sent; not up. If a gateway round is pending, run: vpn login (fresh)."
}

# vpn login                 -> drive both SAML rounds from this terminal
# vpn login --callback STR  -> inject a single callback (fallback)
cmd_login() {
	if [ "${1:-}" = "--callback" ]; then shift; _login_callback "$*"; return $?; fi
	if _tun0_up; then _log "login: already connected (tun0 up) -- nothing to do."; return 0; fi
	command -v tmux >/dev/null 2>&1 || { _log "login: needs tmux -- run this on finley-ub-dt."; return 1; }
	mkdir -p "${_STATE_DIR}" 2>/dev/null || true
	# Clear a STUCK previous login attempt so round 2 can bind its port -- but only
	# disconnect if a gpclient is actually running. A blind disconnect when nothing
	# is running would log out a server session a reboot might have left alive.
	if pgrep -f '/usr/bin/gpclient .*connect vpn\.nps\.edu' >/dev/null 2>&1; then
		sudo -n /usr/bin/gpclient disconnect >/dev/null 2>&1 || true
	fi
	tmux kill-session -t "${_GPAUTH_TMUX}" 2>/dev/null || true
	tmux new-session -d -s "${_GPAUTH_TMUX}" -x 220 -y 50
	# Prefer the widened reconnect-timeout dial (rides out dongle outages on the same
	# session). Fall back to the plain dial if the installed sudoers hasn't been
	# updated for it, so a stale sudoers can never break login -- reinstall
	# net/sudoers.d/nps-vpn (run ~/vpnfix.sh) to actually get the longer window.
	local _login_dial="sudo -n /usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache --reconnect-timeout ${NET_RECONNECT_TIMEOUT} --browser remote"
	if ! sudo -n -l /usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache --reconnect-timeout "${NET_RECONNECT_TIMEOUT}" --browser remote >/dev/null 2>&1; then
		_login_dial="sudo -n /usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache --browser remote"
	fi
	tmux send-keys -t "${_GPAUTH_TMUX}" \
		"${_login_dial}" C-m
	local host
	host="$(hostname -s 2>/dev/null || hostname)"
	printf '\n' >&2
	_log "==== NPS VPN login (running on ${host}; this must be finley-ub-dt) ===="
	_log "TWO quick SAML rounds. For EACH: on your LAPTOP run the one ssh -L +"
	_log "open the URL, finish in the browser (silent if your Microsoft session"
	_log "is live), then paste the callback back HERE. Move fast -- each URL is"
	_log "single-use and expires in a few minutes."
	_log "======================================================================"
	_login_round portal  || { _log "login: portal round did not complete."; return 1; }
	_login_round gateway || { _log "login: gateway round did not complete."; return 1; }
	local i
	for i in $(seq 1 30); do _tun0_up && break; sleep 1; done
	if _tun0_up; then
		date +%s >"${_MINT_FILE}"; rm -f "${_STATE_DIR}/cookie_expired" 2>/dev/null
		_log "login: CONNECTED. Normalising routes/DNS/MTU + laying tunnels..."
		ensure_vpn >/dev/null 2>&1 || true
		ensure_tunnels
		_log "login: done -- 30-day session active. Verify with: vpn-status"
	else
		_log "login: callbacks submitted but tun0 didn't appear. Inspect: tmux attach -t ${_GPAUTH_TMUX}"
		return 1
	fi
}
# Report the SSO cookie's age and any measured lifetimes.
cmd_cookie() {
	if [ -r "${_MINT_FILE}" ]; then
		local mint now age_h
		mint="$(cat "${_MINT_FILE}")"
		now="$(date +%s)"
		age_h=$(( (now - mint) / 3600 ))
		echo "cookie minted: $(date -d "@${mint}" 2>/dev/null)  (age ~${age_h}h)"
	else
		echo "cookie minted: unknown (no interactive 'vpn login' recorded yet)"
	fi
	if [ -r "${_STATE_DIR}/cookie_lifetime.log" ]; then
		echo "measured lifetimes:"
		tail -5 "${_STATE_DIR}/cookie_lifetime.log" | sed 's/^/  /'
	fi
	_tun0_up && echo "state: tun0 UP" || echo "state: tun0 down"
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
login) shift; cmd_login "$@" ;;
cookie) cmd_cookie ;;
*)
	echo "usage: $0 {up|vpn|login|tunnels|status|cookie|down|reconnect|heal|install-autoheal|remove-autoheal}" >&2
	exit 2
	;;
esac
