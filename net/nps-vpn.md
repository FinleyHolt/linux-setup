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

### Headless SAML (no display on this box)

The embedded GTK auth browser cannot start on a headless host ("Failed to
initialize GTK"). Use gpclient's remote-browser mode instead (sudoers already
allows it NOPASSWD):

```bash
# Terminal 1 — on this host, inside tmux (this process IS the VPN once up):
sudo -n /usr/bin/gpclient --fix-openssl connect vpn.nps.edu --cookie-cache --browser remote
# it prints  http://<IP>:<PORT>/<token>  and waits
```

```bash
# Terminal 2 — on the machine with the browser (LAN reachability to <IP>
# is often blocked; the ssh forward always works):
ssh -L <PORT>:<IP>:<PORT> <this-host>
# then open  http://localhost:<PORT>/<token>  and complete the SSO.
```

If the final page shows an "Open GlobalProtect" button instead of finishing,
right-click it → Copy link (a `globalprotectcallback:...` string) and paste
that into Terminal 1. NPS runs TWO SAML rounds (portal, then gateway) — expect
the dance twice, second round usually auto-redirects. `--cookie-cache` makes
the result persist so the autoheal reconnects silently afterwards.

### Unattended self-healing

```bash
~/Github/linux-setup/net/nps-vpn.sh install-autoheal   # user crontab, every 2 min
```

Reconciles VPN + split route + MTU + tunnels unattended (flock-guarded,
log at `~/.local/state/nps-vpn/autoheal.log`, no root, survives reboot).
The only event it cannot heal alone is a server-side SAML-cookie expiry —
that needs the Headless SAML dance above once.

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
