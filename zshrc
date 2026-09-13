# Set the location of Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"
export EDITOR=nvim
export VISUAL=nvim

# Add ~/.local/bin to PATH for locally installed tools (claude, etc.)
export PATH="$HOME/.local/bin:$PATH"

ZSH_THEME=""

plugins=(
    git
    zsh-syntax-highlighting
    zsh-autosuggestions
)

# Load Oh My Zsh.
source $ZSH/oh-my-zsh.sh

# Custom prompt - username and current path relative to home
PROMPT='finley-ub-dt %~ %# '

alias anki="flatpak run net.ankiweb.Anki"

# Source machine-specific local configuration (not tracked in git)
# This file is created by setup-ubuntu.sh and contains micromamba initialization
if [ -f "$HOME/.zshrc.local" ]; then
    source "$HOME/.zshrc.local"
fi

# >>> Claude Code (desktop migration) >>>
export PATH="$HOME/.npm-global/bin:$PATH"
# <<< Claude Code (desktop migration) <<<

# >>> Claude Code: resume sessions the phone started >>>
# A session started from the claude.ai / mobile Code app runs on this box as
# `claude --print --sdk-url …` under the `claude rc` daemon and stamps every
# transcript record entrypoint=sdk-cli. The /resume picker hides sdk
# entrypoints unless the running process is one itself, so a plain
# `claude -r` never lists them. Only the resume forms get the env var: a
# fresh session under it would be stamped sdk-cli too. CLAUDE_CODE_ARTIFACT
# keeps the Artifact tool, which an sdk entrypoint otherwise drops.
# A session the app still shows as running has a live worker appending to
# its transcript, and the interactive resume has no guard against a second
# writer. The registry (~/.claude/sessions/<pid>.json) says which ones are
# live: an explicit id that is live gets --fork-session, and the bare picker
# form lists the live ids first so they are picked by id, not by row.
_claude_live_phone() {
    python3 - <<'PY'
import glob, json, os
for f in glob.glob(os.path.expanduser('~/.claude/sessions/*.json')):
    try:
        d = json.load(open(f)); os.kill(d['pid'], 0)
    except Exception:
        continue
    if d.get('entrypoint') == 'sdk-cli':
        print(d['sessionId'], d.get('name', ''))
PY
}
claude() {
    if [[ " $* " == *" -r "* || " $* " == *" --resume"* ]]; then
        local live id
        live=$(_claude_live_phone)
        for id in "$@"; do
            [[ "$id" == ????????-????-????-????-???????????? ]] || continue
            if [[ "$live" == *"$id"* && " $* " != *" --fork-session "* ]]; then
                print -u2 "session $id is live under the phone: forking"
                set -- "$@" --fork-session
            fi
        done
        if [[ -n "$live" && " $* " != *" --fork-session "* ]]; then
            print -u2 "live under the phone (resume by id to fork, not by row):"
            print -u2 -- "$live"
        fi
        CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_ARTIFACT=1 command claude "$@"
    else
        command claude "$@"
    fi
}
# <<< Claude Code: resume sessions the phone started <<<

# >>> nps vpn command (desktop migration) >>>
# Mirrors the laptop's `vpn` family. Brings up the NPS GlobalProtect split
# tunnel (route + MTU + split DNS) via linux-setup/net/nps-vpn.sh. Passwordless
# sudo for the exact gpclient/ip vectors is granted by
# /etc/sudoers.d/drone-nps-vpn.
# It lays no port forwards: a project that needs a service port brings its own
# per-site tunnel (WORLDSInternal: compute/networking/net_ensure.sh).
# NOTE: the FIRST GlobalProtect SAML login is GUI-only (use the GlobalProtect
# app on the desktop once); after that `vpn` reconnects/heals headlessly while
# GP's auth cookie is valid.
export _NET_ENSURE="$HOME/Github/linux-setup/net/nps-vpn.sh"
vpn() {
    case "${1:-}" in
    login)
        shift
        "$_NET_ENSURE" login "$@"
        return
        ;;
    cookie)
        "$_NET_ENSURE" cookie
        return
        ;;
    bookmarklet)
        "$_NET_ENSURE" bookmarklet
        return
        ;;
    esac
    "$_NET_ENSURE" up
}
vpn-up() { vpn "$@"; }
vpn-status() { "$_NET_ENSURE" status; }
vpn-reconnect() { "$_NET_ENSURE" reconnect; }
vpn-login() { "$_NET_ENSURE" login "$@"; }
vpn-cookie() { "$_NET_ENSURE" cookie; }
vpn-bookmarklet() { "$_NET_ENSURE" bookmarklet; }
vpn-logout() { # DESTRUCTIVE: drops the VPN AND logs out the 30-day NPS session
    if read -q "?This LOGS OUT NPS (you'll need 'vpn login' to reconnect). Proceed? [y/N] "; then
        print
        ip link show tun0 &>/dev/null && sudo -n /usr/bin/gpclient disconnect 2>/dev/null
        print "NPS VPN disconnected -- reconnect with: vpn login"
    else
        print "\naborted (VPN left up)."
    fi
}
alias nps-vpn='vpn'
alias nps-vpn-reconnect='vpn-reconnect'
alias nps-vpn-logout='vpn-logout'
# Warn at the prompt when the SSO cookie has expired -- the one thing autoheal
# can't self-heal (only `vpn login` can). The marker is dropped by nps-vpn.sh's
# autoheal tick; this meets you at the terminal, no phone app needed.
[[ -o interactive ]] && [[ -f "$HOME/.local/state/nps-vpn/cookie_expired" ]] &&
    print -P "%F{red}%B⚠ NPS VPN down%b — SSO cookie expired. Reconnect: %Bvpn login%b%f"
# <<< nps vpn command (desktop migration) <<<

