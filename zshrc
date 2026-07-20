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



# >>> nps vpn command (desktop migration) >>>
# Mirrors the laptop's `vpn` family. Brings up the NPS GlobalProtect split
# tunnel + HPC service tunnels (autossh, ports 8001/8772/8780/8781/8790) via
# linux-setup/net/nps-vpn.sh. Passwordless sudo for the exact gpclient/ip
# vectors is granted by /etc/sudoers.d/drone-nps-vpn.
# NOTE: the FIRST GlobalProtect SAML login is GUI-only (use the GlobalProtect
# app on the desktop once); after that `vpn` reconnects/heals headlessly while
# GP's auth cookie is valid.
export _NET_ENSURE="$HOME/Github/linux-setup/net/nps-vpn.sh"
# `vpn`      -> GlobalProtect split tunnel + HPC service tunnels.
# `vpn edge` -> also raise SOCKS 1080 and launch the .mil Edge (needs
#               microsoft-edge-stable; warns + skips if absent).
vpn() {
    local socks=0 launch_edge=0
    case "${1:-}" in
        edge|--edge) socks=1080; launch_edge=1 ;;
        login)  shift; "$_NET_ENSURE" login "$@"; return ;;
        cookie) "$_NET_ENSURE" cookie; return ;;
    esac
    NET_SOCKS_PORT="$socks" "$_NET_ENSURE" up
    (( launch_edge )) && _edge_mil
}
vpn-up()        { vpn "$@"; }
vpn-status()    { "$_NET_ENSURE" status; }
vpn-reconnect() { "$_NET_ENSURE" reconnect; }
vpn-login()     { "$_NET_ENSURE" login "$@"; }
vpn-cookie()    { "$_NET_ENSURE" cookie; }
vpn-stop() {    # tear down the HPC service tunnels only -- leaves the VPN UP
  "$_NET_ENSURE" down
}
vpn-logout() {  # DESTRUCTIVE: drops the VPN AND logs out the 30-day NPS session
  if read -q "?This LOGS OUT NPS (you'll need 'vpn login' to reconnect). Proceed? [y/N] "; then
    print
    "$_NET_ENSURE" down
    ip link show tun0 &>/dev/null && sudo -n /usr/bin/gpclient disconnect 2>/dev/null
    print "NPS VPN disconnected -- reconnect with: vpn login"
  else
    print "\naborted (VPN left up)."
  fi
}
alias nps-vpn='vpn'
alias nps-vpn-reconnect='vpn-reconnect'
alias nps-vpn-stop='vpn-stop'
alias nps-vpn-logout='vpn-logout'
# .mil Edge helper (only used by `vpn edge`; needs microsoft-edge-stable).
_edge_mil() {
    local i
    for i in {1..10}; do
        ss -tln 2>/dev/null | grep -q '127.0.0.1:1080 ' && break
        sleep 0.5
    done
    if ! ss -tln 2>/dev/null | grep -q '127.0.0.1:1080 '; then
        echo "edge(.mil): SOCKS 1080 never came up (cobra unreachable?) -- not launching proxied Edge." >&2
        return 1
    fi
    command -v microsoft-edge-stable >/dev/null 2>&1 || { echo "edge(.mil): microsoft-edge-stable not installed on this host." >&2; return 1; }
    nohup microsoft-edge-stable \
        --user-data-dir="$HOME/.config/microsoft-edge-genai-mil" \
        --no-first-run --no-default-browser-check \
        --proxy-server="socks5://127.0.0.1:1080" \
        --proxy-bypass-list='<-loopback>' \
        "$@" >/tmp/edge-genai-mil.log 2>&1 &!
}
# Auto-heal HPC tunnels on every interactive shell (backgrounded, idempotent;
# off-VPN the autossh just retries quietly until `vpn` brings the link up).
[[ -o interactive ]] && [[ -x "$_NET_ENSURE" ]] && ( flock -n /tmp/nps-vpn-tunnels.lock "$_NET_ENSURE" tunnels >/dev/null 2>&1 ) &!
# Warn at the prompt when the SSO cookie has expired -- the one thing autoheal
# can't self-heal (only `vpn login` can). The marker is dropped by nps-vpn.sh's
# autoheal tick; this meets you at the terminal, no phone app needed.
[[ -o interactive ]] && [[ -f "$HOME/.local/state/nps-vpn/cookie_expired" ]] && \
    print -P "%F{red}%B⚠ NPS VPN down%b — SSO cookie expired. Reconnect: %Bvpn login%b%f"
# <<< nps vpn command (desktop migration) <<<
