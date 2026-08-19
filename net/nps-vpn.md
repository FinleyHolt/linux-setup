# NPS HPC networking (laptop)

Laptop-side GlobalProtect VPN + HPC SSH tunnels. Lives here (dotfiles), **not**
in any project repo, so the `vpn` command works regardless of which
`DroneProjects-*` worktree/branch is checked out.

- Script: [`net/nps-vpn.sh`](nps-vpn.sh) — `~/.zshrc` points `_NET_ENSURE` at it.
- Sudoers: [`net/sudoers.d/nps-vpn`](sudoers.d/nps-vpn) → `/etc/sudoers.d/nps-vpn`.
- MTU sweep harness: [`net/vpn_mtu_test.sh`](vpn_mtu_test.sh).

## Commands (`~/.zshrc` wrappers)

| command | effect |
|---|---|
| `vpn` | VPN + safe MTU + HPC service tunnels (no SOCKS / organic Edge) |
| `vpn edge` | same, plus SOCKS 1080 + the cobra-routed `.mil` Edge |
| `vpn-status` | VPN state, tun0 MTU, per-port state, **real HPC SSH health** |
| `vpn-reconnect` | force a clean GlobalProtect re-handshake (stale-session fix) |
| `vpn-stop` | tear down tunnels + disconnect GlobalProtect |
| `edge` | organic Microsoft Edge (direct, default profile) |

CLI: `nps-vpn.sh {up|vpn|tunnels|status|down|reconnect|heal}`. The `vpn`
subcommand does the VPN step only (connect + split route + MTU + health) — it
is what project repos delegate to (see *Project delegation* below).

## Failure modes & fixes

### 1. MTU black hole (SSH hangs off-campus) — the main one

**Symptom:** `ssh cobra` opens TCP and exchanges SSH banners, then hangs at
`debug1: expecting SSH2_MSG_KEX_ECDH_REPLY`. `vpn-status` → `HPC SSH: FAIL`.

**Cause:** GlobalProtect brings `tun0` up at MTU 1422; on residential / Xfinity
/ CGNAT / PPPoE underlays the true path MTU is lower and PMTUD is black-holed.
Small packets pass; the large `SSH2_MSG_KEX_ECDH_REPLY` (big with the
`sntrup761x25519` PQ kex) is dropped.

**Fix (automatic):** `nps-vpn.sh` sets `tun0` MTU to `NET_TUN_MTU` (default
1280, the IPv6 minimum) after every connect, and re-asserts on `tunnels`/`heal`.

**If 1280 still fails somewhere:** `NET_TUN_MTU=1200 vpn`, or re-tune with
`bash net/vpn_mtu_test.sh` (sweeps descending MTUs, leaves tun0 at the largest
that works, logs to `/tmp/vpn_mtu_test.log`). Reference (Xfinity, 2026-06-15):
1422 stalls, 1380 works; 1280 chosen for cross-network headroom.

### 2. Stale `tun0` after switching networks

`tun0` lingers but the session is dead; plain `vpn` won't re-auth. `vpn-status`
shows `tun0 UP` + `HPC SSH: FAIL`. Fix: **`vpn-reconnect`**. `up` also now treats
"HPC direct **and** no tun0" as the only genuine on-campus case.

### 3. Local subnet overlaps the split route

Benign on a typical /24 (e.g. Xfinity `172.20.20.0/24` is more specific than the
VPN's `172.20.0.0/16`, so local LAN stays local and only non-local `172.20.x`
HPC hosts route via tun0). Only a problem if a network hands you a `172.20`
block that contains an HPC IP.

### 4. DNS for `*.nps.edu` doesn't resolve

Use the IP host alias (`ssh hamming-ip` → `172.20.32.70`); cobra is IP-addressed.

### 5. GlobalProtect needs interactive SSO / HIP re-auth

`tun0` never appears and the script warns. The SSO cookie expired. With the
`--cookie-cache` sudoers entries installed this is rare (the portal auth
cookie persists across reconnects); when it does happen, see "Headless SAML"
below — a desktop session is NOT required.

### 6. Dial wedged on a webview nobody can see

**Symptom:** no `tun0`, `*.nps.edu` DNS fails, and a `gpclient ... connect
vpn.nps.edu` has been running for hours. Every `vpn` matches the in-flight
guard and logs "already in flight -- waiting on it", forever. Tail of
`~/.local/state/nps-vpn/last_connect.log`: `browser=embedded`, then
`Window not raised: Failed to raise window: GlobalProtect Login`.

**Cause:** the cookie expired, so the dial needed SAML. The headless design
assumes the embedded browser cannot start (`Failed to initialize GTK`) and is
caught by that log line — but finleydt runs an `Xvfb :99` for Playwright, and
`DISPLAY` rides through `sudo` on its built-in `env_keep`. gpauth *found* a
display, opened an auth window nobody can see, and waited. Too headed to fail,
too headless to finish.

**Fix (automatic):** the dial now runs under `env -u DISPLAY -u
WAYLAND_DISPLAY -u XAUTHORITY`, so it fails in seconds on any caller's
environment, and a dial older than `NET_DIAL_WEDGED_AFTER` (300s; a human
`--browser remote` round is exempt) is reported wedged instead of waited on —
it drops the `cookie_expired` marker and stops. Recover with `vpn login`.
Guard: `net/test_stale_dial.sh`.

### Headless SAML (no display on this box)

The embedded GTK auth browser cannot start on a headless host ("Failed to
initialize GTK"), so gpclient runs in remote-browser mode and the browser is
whatever device you are holding. One command drives both rounds:

```bash
vpn login          # on this host; needs tmux, sudoers already allows the dial
```

Per round it prints ONE link on the Tailscale address:

```
http://<tailscale-ip>:18080/<token>
```

Open it on the phone or the laptop — both are tailnet nodes, so neither needs
a tunnel. gpauth itself binds only this box's LAN address on a fresh ephemeral
port, which is why the link is a socat forward from a fixed port; the forward
binds the Tailscale address alone and is torn down when the round's callback
is read. `NET_AUTH_RELAY_PORT` moves the port. With tailscaled down, `vpn
login` falls back to printing the old `ssh -L <PORT>:<IP>:<PORT>` recipe.

Finish the SSO, then hand the `globalprotectcallback:...` string back to the
`vpn login` prompt:

| Last page | Laptop | Phone |
|---|---|---|
| "Open GlobalProtect" button | right-click → Copy link | long-press → Copy Link |
| auto-redirected, browser rejects the address | copy it from the failed tab's address bar | `vpn bookmarklet` → save once as a bookmark, tap it on that page, copy the textarea |

The bookmarklet exists because iOS Safari answers an unknown URL scheme with a
bare "address is invalid" alert and keeps the address out of reach; it lifts
the callback out of the page still loaded underneath the alert.

NPS runs TWO SAML rounds (portal, then gateway) — expect the dance twice, the
second usually auto-redirects. `--cookie-cache` makes the result persist so the
autoheal reconnects silently afterwards.

`net/test_auth_relay.sh` is the guard on the forward: it stands a throwaway
HTTP server in for gpauth and checks reachability, the tailnet-only bind, and
the release.

### Unattended self-healing

```bash
~/Github/linux-setup/net/nps-vpn.sh install-autoheal   # user crontab, every 2 min
```

Reconciles VPN + split route + MTU + tunnels unattended (flock-guarded,
log at `~/.local/state/nps-vpn/autoheal.log`, no root, survives reboot).
The only event it cannot heal alone is a server-side SAML-cookie expiry —
that needs the Headless SAML dance above once.

**Never pause the cron for a login.** It already stands down on its own:
`_saml_reauth_needed` returns false while a `--browser remote` dial is
running, and `ensure_vpn` never stacks a second gpclient. A hand-commented
crontab line sat paused for 12 days, and because the tick is what writes the
`cookie_expired` marker, the next expiry went unannounced. Restore the line
with `nps-vpn.sh install-autoheal`.

## One-time install

```bash
cd ~/Github/linux-setup
sudo install -o root -g root -m 0440 net/sudoers.d/nps-vpn /etc/sudoers.d/nps-vpn
sudo visudo -cf /etc/sudoers.d/nps-vpn            # must print "parsed OK"
sudo rm -f /etc/sudoers.d/drone-nps-vpn           # remove the old project drop-in
```

## Project delegation

DroneProjects' `scripts/net_ensure.sh` still owns its profile-driven HPC tunnel
orchestration (used by `compute/bringup.sh`, `hpc/serve/*.sh`, …), but its VPN
step delegates here: when `~/Github/linux-setup/net/nps-vpn.sh` is present it
calls `nps-vpn.sh vpn`, so the MTU/health logic lives in exactly one place. On
the cluster (no dotfiles, VPN not needed) it falls back to its inline no-op.

## Quick troubleshooting

```bash
vpn-status                 # tun0 MTU + real HPC SSH health
vpn-reconnect              # stale session after a network change
NET_TUN_MTU=1200 vpn       # constrained network: lower the MTU
bash ~/Github/linux-setup/net/vpn_mtu_test.sh   # empirically re-find the MTU
```
