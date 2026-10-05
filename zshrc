# Oh My Zsh and its two plugins are installed by setup.sh.
export ZSH="$HOME/.oh-my-zsh"
export EDITOR=nvim
export VISUAL=nvim
export PATH="$HOME/.local/bin:$PATH"

ZSH_THEME=""
plugins=(
    git
    zsh-syntax-highlighting
    zsh-autosuggestions
)
source "$ZSH/oh-my-zsh.sh"

PROMPT='%n %~ %# '

# micromamba, which setup.sh puts in ~/.local/bin.
if [ -x "$HOME/.local/bin/micromamba" ]; then
    export MAMBA_ROOT_PREFIX="$HOME/micromamba"
    eval "$("$HOME/.local/bin/micromamba" shell hook --shell zsh)"
    mamba() { micromamba "$@"; }
fi

# `y` opens yazi and leaves the shell in the directory yazi was in on quit.
y() {
    local tmp cwd
    tmp="$(mktemp -t yazi-cwd.XXXXXX)"
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        builtin cd -- "$cwd"
    fi
    rm -f -- "$tmp"
}

# Machine-specific config and secrets live outside this repo: every
# ~/.config/zsh/*.zsh, then ~/.zshrc.local.
for f in "$HOME"/.config/zsh/*.zsh(N); do
    source "$f"
done
unset f
if [ -f "$HOME/.zshrc.local" ]; then
    source "$HOME/.zshrc.local"
fi
