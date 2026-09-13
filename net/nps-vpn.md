# NPS HPC networking (laptop)

Laptop-side GlobalProtect VPN link: connect, split route, safe MTU, split DNS.
Lives here (dotfiles), **not** in any project repo, so the `vpn` command works
regardless of which worktree/branch is checked out.

It lays no port forwards. A project that needs a service port carries its own
per-site tunnel layer (WORLDSInternal: `compute/networking/net_ensure.sh`),
which derives the ssh target and the forward set from the site actually running
the daemons. This script owns the LINK; a project owns its ports.

- Script: [`net/nps-vpn.sh`](nps-vpn.sh) — `~/.zshrc` points `_NET_ENSURE` at it.
- Sudoers: [`net/sudoers.d/nps-vpn`](sudoers.d/nps-vpn) → `/etc/sudoers.d/nps-vpn`.
- MTU sweep harness: [`net/vpn_mtu_test.sh`](vpn_mtu_test.sh).

## Commands (`~/.zshrc` wrappers)

| command | effect |
|---|---|
| `vpn` | VPN + split route + safe MTU + split DNS |
| `vpn-status` | the dial vector sudoers grants, VPN state, tun0 MTU, split-DNS scope, **real HPC SSH health** (the one ssh this script runs; by hand only) |
| `vpn-reconnect` | force a clean GlobalProtect re-handshake (stale-session fix) |
| `vpn-logout` | disconnect GlobalProtect (drops the 30-day session) |
| `edge` | organic Microsoft Edge (direct, default profile) |

CLI: `nps-vpn.sh {up|vpn|status|reconnect|heal|login|cookie|bookmarklet}`.
`up` and `vpn` are the same thing — the link step — and `vpn` is the name
project repos delegate to (see *Project delegation* below).

## Failure modes & fixes

### 1. MTU black hole (SSH hangs off-campus) — the main one

**Symptom:** `ssh hamming` opens TCP and exchanges SSH banners, then hangs at
`debug1: expecting SSH2_MSG_KEX_ECDH_REPLY`. `vpn-status` → `HPC SSH: FAIL`.

**Cause:** GlobalProtect brings `tun0` up at MTU 1422; on residential / Xfinity
/ CGNAT / PPPoE underlays the true path MTU is lower and PMTUD is black-holed.
Small packets pass; the large `SSH2_MSG_KEX_ECDH_REPLY` (big with the
`sntrup761x25519` PQ kex) is dropped.

**Fix (automatic):** `nps-vpn.sh` sets `tun0` MTU to `NET_TUN_MTU` (default
1280, the IPv6 minimum) after every connect, and re-asserts on every reconcile.

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

Use the IP host alias (`ssh hamming-ip` → `172.20.32.70`). The health probe and
the keepalive already address the box numerically for this reason.

### 5. GlobalProtect needs interactive SSO / HIP re-auth

`tun0` never appears; the dial's log (`~/.local/state/nps-vpn/last_connect.log`)
says `SAML auth launch`. The server session is gone: the 30-day login
lifetime ran out, or — far more often — the client logged it out on its way
down after an underlay blip (mode 8). The autoheal ends the dial the moment
that line appears, drops the `cookie_expired` marker (the zshrc prompt warns
on it, and a Taildrop note goes to `NET_NOTIFY_PEER`), and stops dialing.
See "Headless SAML" below — a desktop session is NOT required. `vpn cookie`
shows how long each session lasted; `session.log` (below) says why it ended.

### 6. Dial wedged on a webview nobody can see

**Symptom:** no `tun0`, `*.nps.edu` DNS fails, and a `gpclient ... connect
vpn.nps.edu` has been running for hours. Tail of
`~/.local/state/nps-vpn/last_connect.log`: `browser=embedded`, then
`Window not raised: Failed to raise window: GlobalProtect Login`.

**Cause:** the session was gone, so the dial needed SAML. finleydt runs an
`Xvfb` for Playwright and a user session bus, and gpauth finds them even
with `DISPLAY` unset: it opens an auth window nobody can see and waits. Too
headed to fail, too headless to finish. One such dial held the cron's flock
for eight hours (the fd rode along into the `setsid` child) and every tick
was skipped, including the one that would have reported it.

**Fix (automatic):** the dial is ended through its gpauth (which runs as
you, under the root gpclient) as soon as its log says SAML — inside the same
tick, not at a threshold — and any dial older than `NET_DIAL_WEDGED_AFTER`
(300 s; a human `--browser remote` round is exempt) is ended the same way.
The crontab line runs `flock -n -o`, so the tick's children never hold its
lock. Recover with `vpn login`. Guard: `net/test_stale_dial.sh`.

### 7. A name resolves but the connect hangs — subnet outside the split

**Symptom:** `ssh jensen` (or any new NPS host) hangs with no banner, no
refusal, no timeout message. DNS is fine — the name resolves. `vpn-status` says
`HPC SSH: OK`, because hamming is on a prefix that IS routed.

**Cause:** split DNS is scoped to `~nps.edu`, so *every* NPS name resolves the
moment tun0 is up. The split ROUTE is a short list of prefixes. A host whose
subnet is not on that list resolves correctly and then leaves over the LAN
default toward a private address the local network does not route: no RST, no
ICMP, just a hang. Cost real time when the DGX GB300 landed on `10.0.248.0/24`
(2026-08-26) while the split carried `172.20.0.0/16` alone.

**Diagnose:** `ip route get <ip>` — if it names your LAN interface instead of
`tun0`, that is the whole story. `nps-vpn.sh status` lists every prefix and
flags the ones not routed.

**Fix:** add the prefix to `NET_SPLIT_ROUTES` in `nps-vpn.sh` **and** add its
`add`/`del` pair to `net/sudoers.d/nps-vpn`. Both, always: a sudoers glob cannot
follow a shell variable, and the asserts run under `sudo -n ... 2>/dev/null ||
true`, so a prefix listed in only the script fails silently and forever.

### 8. Underlay blip ends the session (ESP fallback)

**Symptom:** the WiFi roams or the dongle drops for seconds; `tun0` is gone
13 s later; the next dial needs SAML. `session.log` reads `ESP detected dead
peer` → `Failed to connect ESP tunnel; using HTTPS instead` → `Failed to
reconnect to host vpn.nps.edu` → `POST .../logout.esp` → `openconnect_mainloop
returned -22`, with `RECONNECT_TIMEOUT: 1200` printed at the top and no
`sleep Ns, remaining timeout` line anywhere.

**Cause:** with ESP (the default transport) openconnect's fallback to HTTPS
is ONE direct `gpst_connect()` (gpst.c, `gpst_mainloop`): its first miss
ends the mainloop, and the client logs the server session out on the way
down. `--reconnect-timeout` never engages on that path; it governs
`ssl_reconnect()`, which only an HTTPS tunnel's own loss reaches. finleydt's
uplink is a USB WiFi dongle on eduroam that roams several times a day, so
this was the "random cookie expiry".

**Fix (automatic):** the dial carries `--no-dtls` (HTTPS-only tunnel), so a
blip goes through the retry loop for `NET_RECONNECT_TIMEOUT` seconds on the
same session. The vectors live in `net/sudoers.d/nps-vpn`; until `~/vpnfix`
has installed them the cascade dials ESP and `vpn-status` says so on its
first line. A wired uplink removes the cause outright.

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

Reconciles VPN + split route + MTU + split DNS unattended (flock-guarded,
no root, survives reboot). The only event it cannot heal alone is a
server-side session end — that needs the Headless SAML dance above once.

A tick never authenticates to anything. With `tun0` up it asserts routes,
MTU and split DNS and sends ONE small ICMP echo through the tunnel to
hamming-sub1 (liveness, and the traffic that holds off the gateway's
180-minute idle timeout). A 2-minute ssh from one address is the shape an
IDS reports as brute force (NPS RC did, 2026-08), and a raw TCP probe of
:22 leaves a line at the login node per tick; neither runs on the timer.
With `tun0` down it dials with the best vector sudoers grants, and a dial
that leaves no tunnel doubles the wait before the next one (2, 4, 8, 16,
32, then 60 min; `net/test_dial_backoff.sh`). A human `vpn` dials at once.

Logs, all under `~/.local/state/nps-vpn/`, each self-truncating at 200 KB:

| file | holds |
|---|---|
| `autoheal.log` | one line per tick |
| `last_connect.log` | the last headless dial's output (what the SAML check reads) |
| `dials.log` | every headless dial's output, under a stamped header |
| `session.log` | the `vpn login` pane, piped to disk — the reason a live session ended is here |
| `cookie_lifetime.log` | how long each session lasted |

**Never pause the cron for a login.** It already stands down on its own:
`_saml_reauth_needed` returns false while a `--browser remote` dial is
running, and `ensure_vpn` never stacks a second gpclient. A hand-commented
crontab line sat paused for 12 days, and because the tick is what writes the
`cookie_expired` marker, the next expiry went unannounced. Restore the line
with `nps-vpn.sh install-autoheal`.

## One-time install

```bash
~/vpnfix        # sudoers (interactive sudo once) + the autoheal crontab; idempotent
```

Re-run it whenever `net/sudoers.d/nps-vpn` gains a vector: the script reads
the installed grants off `sudo -l` and dials the best one it finds, so a
stale install still dials, without the newer protection. `vpn-status`'s
first line is the vector in use.

## Project delegation

WORLDSInternal's `compute/networking/net_ensure.sh` owns per-site tunnel
orchestration: it derives the ssh target and the forward set from the active
site, and lays nothing for a site declaring `on_node` (hamming does, so an
on-node run reaches its own daemons over loopback). Its VPN step delegates
here through `compute/users/finley/networking/link_ensure.sh`, which calls
`nps-vpn.sh vpn`, so the MTU/health logic lives in exactly one place. On the
cluster (no dotfiles, VPN not needed) it falls back to its inline no-op.

Keeping the two apart is what this split is for: a fixed forward set baked into
the link script outlives the box it was written for. This one pointed at a
reclaimed host for nine days after that host was retired, and the 2-minute
reconcile turned into a few failed SSH auths a minute against a dead account —
which NPS's IDS reported as a brute-force attempt on the account (2026-08).

## Quick troubleshooting

```bash
vpn-status                 # dial vector, tun0 MTU, real HPC SSH health
vpn-reconnect              # stale session after a network change
vpn cookie                 # session age + measured lifetimes
tail ~/.local/state/nps-vpn/session.log   # why the last session ended
NET_TUN_MTU=1200 vpn       # constrained network: lower the MTU
bash ~/Github/linux-setup/net/vpn_mtu_test.sh   # empirically re-find the MTU
```
