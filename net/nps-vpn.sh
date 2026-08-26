#!/usr/bin/env bash
# Laptop networking for the NPS HPC LINK: bring up / heal the GlobalProtect VPN,
# set a safe tunnel MTU, and keep the split route and split DNS asserted.
# Self-contained laptop infra -- no dependency on any project repo, so `vpn`
# works regardless of which worktree/branch happens to be checked out.
#
# It lays no port forwards. A project that needs a service port carries its own
# per-site tunnel layer (WORLDSInternal: compute/networking/net_ensure.sh),
# which derives the ssh target and the forward set from the site actually
# running the daemons. This script owns the LINK; a project owns its ports.
#
# Subcommands:
#   up        VPN (if needed) + split route + safe MTU + split DNS   [default]
#   vpn       same as `up`. This is what project repos delegate to for the
#             VPN step.
#   status    VPN state + tun0 MTU + real HPC SSH health
#   reconnect re-assert route/MTU/DNS (NO logout); --force to drop+re-login
#   login     interactive re-auth (headless SAML) after SSO-cookie expiry;
#             prints ONE tailnet URL per round + stamps the cookie mint
#   bookmarklet  print the iOS Safari bookmarklet that lifts the callback
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
#   NET_HPC_HOST      ssh target for the health probe + tunnel keepalive
#                     (default finley.holt@hamming-sub1.uc.nps.edu)
#   NET_HEAL_INTERVAL heal-loop seconds     (default 30)
#   NET_TUN_MTU       tun0 MTU after connect (default 1280; see nps-vpn.md)
#   NET_AUTH_RELAY_PORT  fixed port the SAML round URL is published on (18080)

set -u

# The health probe and the tunnel keepalive both aim here, so it must be a host
# this account really has: a target whose account is gone turns every 2-minute
# reconcile into a failed SSH auth, and a few of those a minute reads to an IDS
# as a brute-force attempt against the account (NPS RC alerted on exactly that,
# 2026-08, when this still pointed at a reclaimed box).
NET_HPC_HOST="${NET_HPC_HOST:-finley.holt@hamming-sub1.uc.nps.edu}"
# The reachability probe and the keepalive ping address the box NUMERICALLY, on
# purpose: hamming's name resolves only through tun0's NPS DNS, so deriving the
# address from NET_HPC_HOST would make the off-VPN on-campus check a DNS failure
# rather than a reachability answer. 172.20.32.70 is hamming-sub1 (ssh hamming-ip).
NET_HPC_IP="${NET_HPC_IP:-172.20.32.70}"
# Split-tunnel prefixes. 172.20.0.0/16 is campus + hamming; 10.0.248.0/24 is the
# ai.nps.edu DGX GB300 (jensen 10.0.248.9, runai 10.0.248.129) -- its names
# resolve through tun0's NPS DNS but its subnet sat outside the split, so every
# ssh to jensen left over the LAN default toward a private /8 nobody there
# routes: no RST, no timeout, just a hang.
#
# Each entry needs its own literal add/del pair in sudoers.d/nps-vpn. A sudoers
# glob cannot follow a shell variable, so adding a prefix here without adding it
# there fails SILENTLY -- the asserts below run under `sudo -n ... || true`.
# That pairing is the reason this stays a hardcoded list and not an env knob.
NET_SPLIT_ROUTES=(172.20.0.0/16 10.0.248.0/24)
NET_HEAL_INTERVAL="${NET_HEAL_INTERVAL:-30}"
# Tunnel MTU. GlobalProtect brings tun0 up at 1422, too high for many real
# underlays (residential / CGNAT / PPPoE): the TCP handshake succeeds but
# large packets -- e.g. SSH's KEX_ECDH_REPLY -- get black-holed and ssh
# stalls forever. 1280 (the IPv6 minimum) has ample headroom on any path.
# gpclient 2.5.x exposes no --mtu, so we set it on tun0 post-connect.
NET_TUN_MTU="${NET_TUN_MTU:-1280}"
# gpauth binds its one-shot SAML auth server to this box's LAN address, on a new
# ephemeral port each round, so the login URL was only openable after an ssh -L.
# `login` forwards that socket to this fixed port on the Tailscale address, which
# both the laptop and the phone already reach -- one tappable link, no ssh -L.
NET_AUTH_RELAY_PORT="${NET_AUTH_RELAY_PORT:-18080}"
# GlobalProtect/openconnect silently restores a DROPPED tunnel to the SAME 30-day
# session (no SAML, no phone MFA) as long as the underlay returns within this
# window. The default is 300s (5 min); a flaky USB WiFi dongle is often out longer
# than that, and once openconnect gives up the session is gone -> full interactive
# SAML + Authenticator push. Widen it so multi-minute dongle outages are ridden
# out silently -- this is the main lever for "fewer logins". 4 digits (the sudoers
# glob bounds it to [0-9][0-9][0-9][0-9]); env-overridable.
NET_RECONNECT_TIMEOUT="${NET_RECONNECT_TIMEOUT:-1200}"
# A headless dial that is still "in flight" after this long is WEDGED, not
# mid-auth: with any display it can reach (an Xvfb for Playwright counts)
# gpclient opens an embedded SAML webview nobody can see and waits forever.
# Bounding it is what turns that into a loud stop -- see _wedged_dial_pid.
NET_DIAL_WEDGED_AFTER="${NET_DIAL_WEDGED_AFTER:-300}"

# --- Cookie-lifetime + expiry state -------------------------------------------
# When the SSO cookie expires the autoheal drops ${_STATE_DIR}/cookie_expired
# (it can't self-heal that -- only an interactive `vpn login` can). An
# interactive-shell hook in zshrc reads that marker and warns at the prompt, so
# a dead VPN meets you at the terminal -- no push service, no extra app.
_STATE_DIR="${HOME}/.local/state/nps-vpn"
_MINT_FILE="${_STATE_DIR}/cookie_minted"       # epoch of last interactive SAML
_CONNECT_LOG="${_STATE_DIR}/last_connect.log"  # output of the last headless dial

_log() { printf '  %s\n' "$*" >&2; }

_hpc_direct() {
	# On-campus: HPC:22 reachable without the VPN.
	timeout 3 bash -c "exec 3<>/dev/tcp/${NET_HPC_IP}/22" >/dev/null 2>&1
}

_tun0_up() { ip link show tun0 >/dev/null 2>&1; }

# True only when EVERY prefix is on tun0, so a partial split (one prefix
# present, one missing) reads as missing and gets re-asserted -- a half-laid
# split is exactly the state that reaches hamming while hanging on jensen.
_split_route_present() {
	local _p
	for _p in "${NET_SPLIT_ROUTES[@]}"; do
		ip route show "${_p}" 2>/dev/null | grep -q 'dev tun0' || return 1
	done
}

# Assert every split prefix on tun0. Idempotent (`ip route add` on an existing
# route is a no-op error we swallow). Callers drop tun0's default route first.
_add_split_routes() {
	local _p
	for _p in "${NET_SPLIT_ROUTES[@]}"; do
		sudo -n /usr/bin/ip route add "${_p}" dev tun0 2>/dev/null || true
	done
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
			_add_split_routes
		else
			_log "VPN: tun0 up, split route present."
		fi
		_set_tun_mtu
		_ensure_split_dns
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
		local _wedged
		if _wedged="$(_wedged_dial_pid)"; then
			_log "VPN: gpclient pid ${_wedged} has been dialing for over"
			_log "     $((NET_DIAL_WEDGED_AFTER / 60))min -- wedged on a SAML webview nobody can see,"
			_log "     not mid-auth. Recover with:  vpn login   (on finley-ub-dt)."
			_record_cookie_expiry
			return 1
		fi
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
		# reconnects need no SAML until the server expires it. --cookie-cache
		# exists from gpclient 2.6; 2.5.x remembers the cookie BY DEFAULT and
		# REJECTS the flag with a usage error — which this branch discards,
		# so a wrong vector reads as "VPN never comes up". Probe the
		# INSTALLED CLIENT first (a 2.5.x box goes straight to the bare
		# command, same cookie behavior), then cascade through the
		# sudoers-allowed vectors.
		local -a _connect=(/usr/bin/gpclient --fix-openssl connect vpn.nps.edu)
		if /usr/bin/gpclient connect --help 2>/dev/null | grep -q -- --cookie-cache; then
			_connect=(/usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache --reconnect-timeout "${NET_RECONNECT_TIMEOUT}")
			if ! sudo -n -l "${_connect[@]}" >/dev/null 2>&1; then
				_connect=(/usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache)
				if ! sudo -n -l "${_connect[@]}" >/dev/null 2>&1; then
					_connect=(/usr/bin/gpclient --fix-openssl connect vpn.nps.edu)
				fi
			fi
		fi
		# setsid -> the VPN client lives in its own session, so it survives
		# this script (and any shell that triggered the heal) exiting.
		mkdir -p "${_STATE_DIR}" 2>/dev/null || true
		# env -u DISPLAY: this box runs an Xvfb for Playwright and DISPLAY rides
		# through sudo on its built-in env_keep, so a cookie-expired dial FOUND a
		# display, opened an invisible auth window and hung for hours instead of
		# failing. Denied a display it fails GTK init in seconds, which is what
		# _saml_reauth_needed was written to catch. `env` precedes `sudo`: the
		# sudoers Cmnd_Alias covers gpclient, not /usr/bin/env.
		setsid env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY \
			sudo -n "${_connect[@]}" >"${_CONNECT_LOG}" 2>&1 &
	fi
	local _i
	for _i in $(seq 1 30); do
		_tun0_up && break
		sleep 1
	done
	if ! _tun0_up; then
		# Record the expiry HERE, not only from the autoheal tick: a paused cron
		# meant the marker (and the zshrc prompt warning that reads it) went
		# unwritten for 12 days while every dial failed.
		_saml_reauth_needed && _record_cookie_expiry
		_log "VPN: WARNING tun0 did not appear."
		_log "     - sudo prompted? install net/sudoers.d/nps-vpn (one-time; see net/nps-vpn.md)."
		_log "     - SAML cookie expired on a headless box? run:"
		_log "         sudo /usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache --browser remote"
		_log "       then open the printed URL through an ssh -L forward (nps-vpn.md, 'Headless SAML')."
		return 1
	fi
	sudo -n /usr/bin/ip route del default dev tun0 2>/dev/null || true
	_add_split_routes
	_log "VPN: split tunnel active (${NET_SPLIT_ROUTES[*]} via tun0)."
	_set_tun_mtu
	_ensure_split_dns
	if _hpc_ssh_ok; then
		_log "VPN: HPC SSH reachable."
	else
		_log "VPN: WARNING connected but HPC SSH still failing. If this is a"
		_log "     constrained network, retry lower:  NET_TUN_MTU=1200 nps-vpn.sh up"
	fi
}

# Reap sshfs mounts whose server went away. With `-o reconnect` sshfs retries
# forever instead of erroring, so every stat on a dead mount blocks with no
# bound -- and since the mountpoints sit directly in $HOME, that wedges anything
# that walks $HOME, shell `cd` completion included (it stats every sibling to
# filter for directories). Left alone a dead mount survives for days; this caps
# it at one tick. A hard-timeout stat is the liveness probe -- FUSE waits are
# killable, so the probe never inherits the hang -- and the unmount is lazy
# because a plain one blocks on the same dead server. Not NPS-specific (field
# boxes hang the same way); it lives here because this is the reconciler that
# already runs every 2 minutes.
_reap_dead_sshfs() {
	local mp
	for mp in $(findmnt -rn -t fuse.sshfs -o TARGET 2>/dev/null); do
		timeout -s KILL 10 stat -c '%i' "$mp" >/dev/null 2>&1 && continue
		_log "sshfs: reaping unresponsive mount ${mp}"
		fusermount3 -u -z "$mp" 2>/dev/null ||
			fusermount -u -z "$mp" 2>/dev/null ||
			umount -l "$mp" 2>/dev/null || true
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

cmd_status() {
	if _hpc_direct && ! _tun0_up; then
		echo "VPN:        not needed (HPC:22 reachable direct)"
	elif _tun0_up; then
		echo "VPN:        tun0 UP (mtu $(cat /sys/class/net/tun0/mtu 2>/dev/null)), split route $(_split_route_present &&
			echo present || echo MISSING)"
		# Name the prefixes individually: a half-laid split reaches hamming while
		# hanging on jensen, and "MISSING" alone does not say which one is gone.
		local _p
		for _p in "${NET_SPLIT_ROUTES[@]}"; do
			printf '  %-16s %s\n' "${_p}" "$(ip route show "${_p}" 2>/dev/null | grep -q 'dev tun0' &&
				echo 'via tun0' || echo 'NOT ROUTED -- traffic leaves over the LAN default')"
		done
		echo "HPC SSH:    $(_hpc_ssh_ok && echo 'OK (key exchange completes)' ||
			echo 'FAIL -- path/MTU/stale; try: nps-vpn.sh reconnect')"
	else
		echo "VPN:        DOWN (no tun0, HPC not direct)"
	fi
	echo "split DNS:  $(resolvectl status tun0 2>/dev/null | grep -q 'DNS Domain:.*~nps\.edu' &&
		echo 'tun0 -> ~nps.edu' || echo 'not scoped (tun0 down, or ~. still set)')"
}

cmd_reconnect() {
	# SAFETY: on NPS, `gpclient disconnect` LOGS OUT the 30-day session and there
	# is no silent cookie reconnect (--cookie-cache jumps to an embedded browser
	# that can't run on a headless box), so a blind disconnect strands you at a
	# full interactive re-login. Default behaviour therefore NEVER disconnects --
	# it re-asserts split route + MTU + DNS, which fixes the common
	# "network changed / tun0 stale" case. Use `reconnect --force` only when you
	# accept that a `vpn login` will be needed afterwards.
	if [ "${1:-}" = "--force" ]; then
		_log "reconnect: --force -- disconnecting. This LOGS OUT the NPS session;"
		_log "           you WILL need a full 'vpn login' afterwards."
		sudo -n /usr/bin/gpclient disconnect 2>/dev/null || true
		local _i
		for _i in $(seq 1 15); do _tun0_up || break; sleep 1; done
		ensure_vpn
		return
	fi
	if ! _tun0_up; then
		_log "reconnect: VPN is down -- NPS needs an interactive login to recover:"
		_log "             vpn login        (run on finley-ub-dt)"
		return
	fi
	_log "reconnect: re-asserting split route + MTU + DNS (no logout)."
	ensure_vpn
	if ! _hpc_ssh_ok; then
		_log "reconnect: WARNING tun0 up but HPC SSH still failing -- session looks"
		_log "           dead. NPS can't silently reconnect; recover with:"
		_log "             vpn login                     (full re-login), or"
		_log "             nps-vpn.sh reconnect --force   (drop first, then re-login)"
	fi
}

cmd_heal() {
	_log "heal: reconcile loop every ${NET_HEAL_INTERVAL}s (Ctrl-C to stop)"
	while true; do
		ensure_vpn >/dev/null 2>&1 || true
		sleep "${NET_HEAL_INTERVAL}"
	done
}

# Unattended self-healing: a user crontab entry reconciles the whole link
# (VPN + split route + MTU + split DNS) every 2 minutes. flock skips a tick
# while the previous one is still running; the log self-truncates. No root
# needed; survives reboots and logouts (cron runs without a session).
_AUTOHEAL_LOG="${HOME}/.local/state/nps-vpn/autoheal.log"
_AUTOHEAL_TAG="# nps-vpn-autoheal"

# Keep GlobalProtect's inactivity timer from firing by pushing a packet through
# tun0 each reconcile. Outbound alone counts -- the gateway resets its idle
# timer on any traffic through the tunnel, reply or not. No-op if tun0 is down.
# This is the ONLY thing generating tunnel traffic on an otherwise idle link,
# so an idle VPN now depends on it rather than on a standing forward.
_link_keepalive() {
	_tun0_up || return 0
	ping -c1 -W1 -I tun0 "${NET_HPC_IP}" >/dev/null 2>&1 || true
}

cmd_autoheal_tick() {
	{
		printf '%s ' "$(date -Is)"
		_reap_dead_sshfs 2>&1 | tr '\n' '|'
		ensure_vpn 2>&1 | tr '\n' '|'
		echo
	} >>"$_AUTOHEAL_LOG"
	if [ "$(stat -c%s "$_AUTOHEAL_LOG" 2>/dev/null || echo 0)" -gt 200000 ]; then
		tail -c 100000 "$_AUTOHEAL_LOG" >"${_AUTOHEAL_LOG}.tmp" &&
			mv "${_AUTOHEAL_LOG}.tmp" "$_AUTOHEAL_LOG"
	fi
	# Detect the one failure autoheal can't fix -- SSO-cookie expiry -- and drop a
	# marker the shell hook warns on. On recovery clear it + send link keepalive.
	if ! _tun0_up && ! _hpc_direct && _saml_reauth_needed; then
		_record_cookie_expiry
	elif _tun0_up; then
		rm -f "${_STATE_DIR}/cookie_expired" 2>/dev/null || true
		_link_keepalive
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
# Echo the pid of a headless dial that has been running longer than
# NET_DIAL_WEDGED_AFTER, non-zero when there is none. The ^ anchor is
# load-bearing: an unanchored pgrep -f also matches any shell whose argv merely
# MENTIONS gpclient (a `zsh -c` wrapper around a diagnostic command does), and
# such a match would read as a wedged VPN.
_wedged_dial_pid() {
	local pid age
	for pid in $(pgrep -f '^/usr/bin/gpclient .*connect vpn\.nps\.edu' 2>/dev/null); do
		# A human is genuinely typing through a --browser remote round; that is
		# never wedged, however long they take.
		case "$(ps -o args= -p "$pid" 2>/dev/null)" in
		*'--browser remote'*) continue ;;
		esac
		age="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
		[ "${age:-0}" -gt "${NET_DIAL_WEDGED_AFTER}" ] && { echo "$pid"; return 0; }
	done
	return 1
}

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
# round it prints ONE tailnet URL: open it on whatever device you are holding,
# finish in the browser, paste the callback back into THIS terminal. No tunnel,
# no second command, no hidden round-2 URL, no machine mix-ups.

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

# This box's Tailscale address -- the one host:port both the phone and the laptop
# can open without a tunnel. Empty when tailscaled is down.
_tailnet_ip() { tailscale ip -4 2>/dev/null | head -1; }

# Forward NET_AUTH_RELAY_PORT on the tailnet address to gpauth's ephemeral LAN
# socket, so the round URL is a stable tappable link. Reachable only from the
# tailnet: socat binds the Tailscale address, not every interface. Echoes the
# host:port to publish, or nothing when it can't (caller falls back to ssh -L).
_auth_relay_up() {
	local ip="$1" port="$2" ts pid
	ts="$(_tailnet_ip)"
	[ -n "$ts" ] || return 1
	command -v socat >/dev/null 2>&1 || return 1
	_auth_relay_down
	socat "TCP-LISTEN:${NET_AUTH_RELAY_PORT},bind=${ts},reuseaddr,fork" \
		"TCP:${ip}:${port}" >/dev/null 2>&1 &
	pid=$!
	sleep 0.3
	kill -0 "$pid" 2>/dev/null || return 1
	printf '%s:%s\n' "$ts" "${NET_AUTH_RELAY_PORT}"
}

# Teardown keys off the port, not a remembered PID: the caller reads the URL out
# of _auth_relay_up through a command substitution, so any PID the function set
# would die with that subshell and the relay would outlive the login.
_auth_relay_down() {
	pkill -f "TCP-LISTEN:${NET_AUTH_RELAY_PORT},bind=" 2>/dev/null
	return 0
}

# iOS Safari refuses the globalprotectcallback: scheme with a bare "address is
# invalid" alert and keeps the URL out of the address bar, so there is nothing to
# copy the way a desktop browser leaves it. This bookmarklet lifts the callback
# out of the page that is still loaded underneath the alert and drops it in a
# textarea to select. Save it once as a bookmark on the phone.
_BOOKMARKLET='javascript:(function(){var m=document.documentElement.outerHTML.match(/globalprotectcallback:[^"'"'"'<>\s]+/);document.open();document.write("<textarea style=\"width:99%;height:70vh;font-size:16px\">"+(m?m[0]:document.documentElement.outerHTML)+"</textarea>");document.close();})()'

cmd_bookmarklet() {
	cat >&2 <<-EOF
		Save this as a bookmark on the phone (name it "GP callback"), then edit the
		bookmark's URL and paste this in place of the address:

	EOF
	printf '%s\n\n' "${_BOOKMARKLET}"
	_log "Use it on the page Safari is showing when it says the address is invalid:"
	_log "dismiss the alert, tap the bookmark, then select-all + copy the textarea."
}

# Wait (~40s) for a SAML round's auth URL. Echo "IP PORT TOKEN" for a local auth
# server (use ssh -L), or "MS <url>" when only the piped Microsoft URL exists.
# Returns 0 with no output if tun0 comes up meanwhile (round not needed).
# -pJ (join wrapped lines) is load-bearing: gpauth's URL line is ~140 chars and
# the pane can come up far narrower than the -x 220 it was created with, so a
# bare -p returns the URL split across rows and the grep silently matches only
# the first fragment. That yields a truncated token, which gpauth answers with a
# bare "Forbidden" -- indistinguishable from an expired URL, and it cost an
# afternoon of re-login attempts once.
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
					url=$(tmux capture-pane -t "${_GPAUTH_TMUX}" -pJ -S -60 2>/dev/null | grep -oE "http://[0-9.]+:${port}/[a-f0-9-]+" | tail -1)
				fi
			fi
		else
			url=$(tmux capture-pane -t "${_GPAUTH_TMUX}" -pJ 2>/dev/null | grep -oE 'http://[0-9.]+:[0-9]+/[a-f0-9-]+' | tail -1)
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

# Drive one SAML round: publish its URL on the tailnet, read the callback from
# THIS terminal, inject it into the gpclient pane.
_login_round() {
	local kind="$1" parts cb msurl pub
	parts=$(_login_round_url "$kind")
	_tun0_up && return 0
	printf '\n' >&2
	# shellcheck disable=SC2086
	set -- $parts
	if [ "${1:-}" = MS ]; then
		msurl="$2"
		_log "-- ${kind} round -- no local URL; using the direct Microsoft URL:"
		if _clip_to_terminal "$msurl"; then
			_log "   -> pushed to your CLIPBOARD; paste it into a browser tab."
		else
			_log "   open this in a browser:"
			printf '  %s\n' "$msurl" >&2
		fi
	elif [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ]; then
		pub="$(_auth_relay_up "$1" "$2")"
		if [ -n "$pub" ]; then
			_log "-- ${kind} round -- open this on the phone or the laptop:"
			printf '\n  http://%s/%s\n\n' "$pub" "$3" >&2
		else
			_log "-- ${kind} round -- no tailnet relay; fall back to a tunnel:"
			_log "     ssh -L ${2}:${1}:${2} finley-ub-dt"
			_log "   then open in your browser:  http://localhost:${2}/${3}"
		fi
	else
		_log "login: couldn't get the ${kind} URL in time. Inspect: tmux attach -t ${_GPAUTH_TMUX}"
		return 1
	fi
	_log "Finish the login. What goes below is the globalprotectcallback: string."
	_log "  'Open GlobalProtect' button on the last page? Its link IS the string:"
	_log "     phone: long-press -> Copy Link.   laptop: right-click -> Copy link."
	_log "  Page redirected instead and the browser rejected the address?"
	_log "     laptop: copy it out of the failed tab's address bar."
	_log "     phone:  dismiss Safari's alert, tap the 'GP callback' bookmarklet"
	_log "             (print it with: vpn bookmarklet), copy the textarea."
	printf '  Paste the %s globalprotectcallback here + Enter:\n  > ' "$kind" >&2
	IFS= read -r cb || { _auth_relay_down; return 1; }
	_auth_relay_down
	# A phone paste can arrive with wrapping whitespace; the callback is a scheme
	# plus base64, so no interior whitespace can be load-bearing.
	cb="${cb//[[:space:]]/}"
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
	_log "TWO quick SAML rounds. For EACH: open the printed link on whatever you"
	_log "are holding -- phone or laptop, both are on the tailnet -- finish in the"
	_log "browser (silent if your Microsoft session is live), then paste the"
	_log "callback back HERE. Move fast: each URL is single-use and expires."
	_log "======================================================================"
	_login_round portal  || { _log "login: portal round did not complete."; return 1; }
	_login_round gateway || { _log "login: gateway round did not complete."; return 1; }
	local i
	for i in $(seq 1 30); do _tun0_up && break; sleep 1; done
	if _tun0_up; then
		date +%s >"${_MINT_FILE}"; rm -f "${_STATE_DIR}/cookie_expired" 2>/dev/null
		_log "login: CONNECTED. Normalising routes/DNS/MTU..."
		ensure_vpn >/dev/null 2>&1 || true
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
up | vpn) ensure_vpn ;;
status) cmd_status ;;
reconnect) cmd_reconnect ;;
heal) cmd_heal ;;
autoheal-tick) cmd_autoheal_tick ;;
install-autoheal) cmd_install_autoheal ;;
remove-autoheal) cmd_remove_autoheal ;;
login) shift; cmd_login "$@" ;;
bookmarklet) cmd_bookmarklet ;;
cookie) cmd_cookie ;;
*)
	echo "usage: $0 {up|vpn|login|bookmarklet|status|cookie|reconnect|heal|install-autoheal|remove-autoheal}" >&2
	exit 2
	;;
esac
