#!/bin/bash

################################################################################
# Development Tools Module
# Neovim, Podman, Tailscale, LaTeX, Micromamba, CLI utilities, and cheat
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

setup_neovim() {
    print_section "Neovim Setup"

    DOTFILES_DIR="$(get_dotfiles_dir)"

    print_step "Installing Neovim..."
    if ! command -v nvim &> /dev/null; then
        if [ "$DISTRO" = "ubuntu" ]; then
            sudo snap install --classic nvim
        elif [ "$DISTRO" = "fedora" ]; then
            pkg_install neovim
        fi
    fi

    # Install Python support for Neovim
    print_step "Installing Python development tools..."
    if [ "$DISTRO" = "ubuntu" ]; then
        pkg_install python3 python3-pip python3-venv
    elif [ "$DISTRO" = "fedora" ]; then
        pkg_install python3 python3-pip python3-virtualenv
    fi

    # Install Node.js (required for many LSP servers)
    print_step "Installing Node.js..."
    if ! command -v node &> /dev/null; then
        if [ "$DISTRO" = "ubuntu" ]; then
            curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
            pkg_install nodejs
        elif [ "$DISTRO" = "fedora" ]; then
            pkg_install nodejs npm
        fi
    fi

    # Install ripgrep, fd, and xclip (for Telescope and clipboard support)
    print_step "Installing ripgrep, fd-find, and xclip..."
    if [ "$DISTRO" = "ubuntu" ]; then
        pkg_install ripgrep fd-find xclip
    elif [ "$DISTRO" = "fedora" ]; then
        pkg_install ripgrep fd-find xclip
    fi

    # Install Rust (required for some Neovim plugins)
    if ! command -v rustc &> /dev/null; then
        print_step "Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi

    print_step "Setting up Neovim configuration..."
    # Create directory structure
    mkdir -p "$HOME/.config/nvim/lua"

    # Link configuration files (only if not already correctly linked)
    if [ ! -L "$HOME/.config/nvim/init.lua" ] || [ "$(readlink "$HOME/.config/nvim/init.lua")" != "$DOTFILES_DIR/nvim/init.lua" ]; then
        [ -f "$HOME/.config/nvim/init.lua" ] && [ ! -L "$HOME/.config/nvim/init.lua" ] && mv "$HOME/.config/nvim/init.lua" "$HOME/.config/nvim/init.lua.backup.$(date +%Y%m%d_%H%M%S)"
        ln -sf "$DOTFILES_DIR/nvim/init.lua" "$HOME/.config/nvim/init.lua"
    fi

    if [ ! -L "$HOME/.config/nvim/lazy-lock.json" ] || [ "$(readlink "$HOME/.config/nvim/lazy-lock.json")" != "$DOTFILES_DIR/nvim/lazy-lock.json" ]; then
        [ -f "$HOME/.config/nvim/lazy-lock.json" ] && [ ! -L "$HOME/.config/nvim/lazy-lock.json" ] && mv "$HOME/.config/nvim/lazy-lock.json" "$HOME/.config/nvim/lazy-lock.json.backup.$(date +%Y%m%d_%H%M%S)"
        ln -sf "$DOTFILES_DIR/nvim/lazy-lock.json" "$HOME/.config/nvim/lazy-lock.json"
    fi

    if [ ! -L "$HOME/.config/nvim/lua/plugins.lua" ] || [ "$(readlink "$HOME/.config/nvim/lua/plugins.lua")" != "$DOTFILES_DIR/nvim/lua/plugins.lua" ]; then
        [ -f "$HOME/.config/nvim/lua/plugins.lua" ] && [ ! -L "$HOME/.config/nvim/lua/plugins.lua" ] && mv "$HOME/.config/nvim/lua/plugins.lua" "$HOME/.config/nvim/lua/plugins.lua.backup.$(date +%Y%m%d_%H%M%S)"
        ln -sf "$DOTFILES_DIR/nvim/lua/plugins.lua" "$HOME/.config/nvim/lua/plugins.lua"
    fi

    # Link plugins directory (contains module files)
    if [ ! -L "$HOME/.config/nvim/lua/plugins" ] || [ "$(readlink "$HOME/.config/nvim/lua/plugins")" != "$DOTFILES_DIR/nvim/lua/plugins" ]; then
        [ -d "$HOME/.config/nvim/lua/plugins" ] && [ ! -L "$HOME/.config/nvim/lua/plugins" ] && mv "$HOME/.config/nvim/lua/plugins" "$HOME/.config/nvim/lua/plugins.backup.$(date +%Y%m%d_%H%M%S)"
        ln -sf "$DOTFILES_DIR/nvim/lua/plugins" "$HOME/.config/nvim/lua/plugins"
    fi

    print_step "Installing Neovim plugins (this may take a moment)..."
    nvim --headless "+Lazy! sync" +qa 2>/dev/null || true

    print_step "Neovim setup complete"
}

setup_podman() {
    print_section "Podman Installation"

    print_step "Installing Podman..."
    if ! command -v podman &> /dev/null; then
        if [ "$DISTRO" = "ubuntu" ]; then
            pkg_install podman podman-docker podman-compose
        elif [ "$DISTRO" = "fedora" ]; then
            pkg_install podman podman-docker podman-compose
        fi
    fi

    # Enable podman socket for Docker API compatibility
    print_step "Enabling Podman socket for Docker API compatibility..."
    systemctl --user enable --now podman.socket 2>/dev/null || true

    print_step "Podman installation complete"
    print_step "Note: 'podman-docker' provides 'docker' command compatibility"
}

setup_tailscale() {
    print_section "Tailscale Installation"

    print_step "Installing Tailscale..."
    if ! command -v tailscale &> /dev/null; then
        if [ "$DISTRO" = "ubuntu" ]; then
            curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
            curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list > /dev/null
            pkg_update
            pkg_install tailscale
        elif [ "$DISTRO" = "fedora" ]; then
            sudo dnf config-manager --add-repo https://pkgs.tailscale.com/stable/fedora/tailscale.repo
            pkg_install tailscale
        fi

        sudo systemctl enable --now tailscaled
    fi

    print_step "Tailscale installation complete"
    print_step "Run 'sudo tailscale up' to authenticate"
}

setup_latex() {
    print_section "LaTeX Installation"

    print_step "Installing LaTeX..."
    if [ "$DISTRO" = "ubuntu" ]; then
        pkg_install texlive-latex-extra texlive-fonts-recommended texlive-xetex
    elif [ "$DISTRO" = "fedora" ]; then
        pkg_install texlive-scheme-medium texlive-xetex
    fi

    print_step "LaTeX installation complete"
}

setup_micromamba() {
    print_section "Micromamba Setup"

    DOTFILES_DIR="$(get_dotfiles_dir)"

    print_step "Installing Micromamba..."
    if ! command -v micromamba &> /dev/null; then
        # Install micromamba
        "${SHELL}" <(curl -L micro.mamba.pm/install.sh) <<EOF
y
$HOME/.local/bin/micromamba
y
EOF

        # Initialize micromamba to zshrc.local (machine-specific, not tracked in git)
        if [ -f "$HOME/.local/bin/micromamba" ]; then
            if ! grep -q "mamba initialize" "$HOME/.zshrc.local" 2>/dev/null; then
                export MAMBA_ROOT_PREFIX="$HOME/micromamba"
                eval "$($HOME/.local/bin/micromamba shell hook --shell zsh)"

                # Run micromamba shell init (this will modify ~/.zshrc which is a symlink to the git repo)
                $HOME/.local/bin/micromamba shell init --shell zsh --root-prefix="$HOME/micromamba" 2>&1 | grep -v "No action taken" || true

                # Extract the mamba initialization block from zshrc and save to zshrc.local
                if grep -q "mamba initialize" "$HOME/.zshrc" 2>/dev/null; then
                    sed -n '/>>> mamba initialize >>>/,/<<< mamba initialize <<</p' "$HOME/.zshrc" > "$HOME/.zshrc.local"
                fi
            fi

            # ALWAYS remove mamba block from git-tracked zshrc (in case it was re-added)
            # Use the actual file path (follow symlink) to ensure sed works correctly
            ZSHRC_REAL_PATH="$DOTFILES_DIR/zshrc"
            if grep -q "mamba initialize" "$ZSHRC_REAL_PATH" 2>/dev/null; then
                # Remove mamba block
                sed -i '/>>> mamba initialize >>>/,/<<< mamba initialize <<</d' "$ZSHRC_REAL_PATH"
                # Remove all trailing blank lines at the end of the file
                printf '%s\n' "$(cat "$ZSHRC_REAL_PATH")" > "$ZSHRC_REAL_PATH"
                print_step "Cleaned up mamba initialization from git-tracked zshrc"
            fi

            print_step "Micromamba installed successfully"
        fi
    else
        print_step "Micromamba is already installed"
        # Check if initialization is needed even though micromamba is installed
        if [ -f "$HOME/.local/bin/micromamba" ]; then
            if ! grep -q "mamba initialize" "$HOME/.zshrc.local" 2>/dev/null; then
                export MAMBA_ROOT_PREFIX="$HOME/micromamba"

                # Run micromamba shell init (this will modify ~/.zshrc which is a symlink to the git repo)
                $HOME/.local/bin/micromamba shell init --shell zsh --root-prefix="$HOME/micromamba" 2>&1 | grep -v "No action taken" || true

                # Extract the mamba initialization block from zshrc and save to zshrc.local
                if grep -q "mamba initialize" "$HOME/.zshrc" 2>/dev/null; then
                    sed -n '/>>> mamba initialize >>>/,/<<< mamba initialize <<</p' "$HOME/.zshrc" > "$HOME/.zshrc.local"
                fi
                print_step "Micromamba initialization added to zshrc.local"
            fi

            # ALWAYS remove mamba block from git-tracked zshrc (in case it was re-added)
            # Use the actual file path (follow symlink) to ensure sed works correctly
            ZSHRC_REAL_PATH="$DOTFILES_DIR/zshrc"
            if grep -q "mamba initialize" "$ZSHRC_REAL_PATH" 2>/dev/null; then
                # Remove mamba block
                sed -i '/>>> mamba initialize >>>/,/<<< mamba initialize <<</d' "$ZSHRC_REAL_PATH"
                # Remove all trailing blank lines at the end of the file
                printf '%s\n' "$(cat "$ZSHRC_REAL_PATH")" > "$ZSHRC_REAL_PATH"
                print_step "Cleaned up mamba initialization from git-tracked zshrc"
            fi
        fi
    fi

    print_step "Micromamba setup complete"
}

setup_cli_utilities() {
    print_section "CLI Utilities"

    print_step "Installing additional utilities..."
    if [ "$DISTRO" = "ubuntu" ]; then
        pkg_install tmux tree htop btop jq fzf tldr imagemagick
    elif [ "$DISTRO" = "fedora" ]; then
        pkg_install tmux tree htop btop jq fzf tldr ImageMagick
    fi

    print_step "CLI utilities installation complete"
}

setup_cheat() {
    print_section "Cheat - Command-line Cheatsheets"

    DOTFILES_DIR="$(get_dotfiles_dir)"

    print_step "Installing cheat for command-line cheatsheets..."
    if ! command -v cheat &> /dev/null; then
        if [ "$DISTRO" = "ubuntu" ]; then
            sudo snap install cheat
        elif [ "$DISTRO" = "fedora" ]; then
            # On Fedora, install from COPR or use Go
            print_warning "Cheat not available via standard repos on Fedora"
            print_warning "You can install manually from: https://github.com/cheat/cheat"
            return
        fi
    fi

    print_step "Configuring cheat..."
    # Snap version of cheat uses ~/snap/cheat/common/.config/cheat/ for config
    mkdir -p "$HOME/snap/cheat/common/.config/cheat"

    # Set community cheatsheets path (snap default location)
    # Note: Community cheatsheets need to be downloaded separately
    # We only add this to config if the directory exists
    COMMUNITY_PATH=""
    if [ -d "$HOME/snap/cheat/common/.config/cheat/cheatsheets/community" ]; then
        COMMUNITY_PATH="$HOME/snap/cheat/common/.config/cheat/cheatsheets/community"
    fi

    # Create cheat configuration in snap directory
    cat > "$HOME/snap/cheat/common/.config/cheat/conf.yml" << EOF
---
# The editor to use with 'cheat -e <sheet>'. Defaults to \$EDITOR or \$VISUAL.
editor: nvim

# Should 'cheat' enable colorized output?
colorize: true

# Which 'chroma' colorscheme should be applied to the output?
# Options are available here:
#   https://github.com/alecthomas/chroma/tree/master/styles
style: monokai

# Which 'chroma' "formatter" should be applied?
# One of: "terminal", "terminal256", "terminal16m"
formatter: terminal256

# Through which pager should output be piped?
pager: less -FRX

# The paths at which cheatsheets are available
cheatpaths:
EOF

    # Add community cheatsheets if path was found
    if [ -n "$COMMUNITY_PATH" ]; then
        cat >> "$HOME/snap/cheat/common/.config/cheat/conf.yml" << EOF

  # Community cheatsheets
  - name: community
    path: $COMMUNITY_PATH
    tags: [ community ]
    readonly: true
EOF
    fi

    # Add personal cheatsheets
    cat >> "$HOME/snap/cheat/common/.config/cheat/conf.yml" << EOF

  # Personal cheatsheets
  - name: personal
    path: $DOTFILES_DIR/cheatsheets
    tags: [ personal ]
    readonly: false
EOF

    print_step "Cheat configured successfully"
    print_step "Available cheatsheets: cheat -l"
    print_step "Python syntax reference: cheat python"
}

setup_claude() {
    print_section "Claude Code CLI"

    print_step "Installing Claude Code CLI..."
    if ! command -v claude &> /dev/null; then
        curl -fsSL https://claude.ai/install.sh | bash
        print_step "Claude Code CLI installed successfully"
    else
        print_step "Claude Code CLI is already installed"
    fi

    print_step "Installing claude-history..."
    if ! command -v claude-history &> /dev/null; then
        # Ensure cargo is available
        if command -v cargo &> /dev/null; then
            cargo install claude-history
            print_step "claude-history installed successfully"
        else
            print_warning "Cargo not found. Skipping claude-history installation."
        fi
    else
        print_step "claude-history is already installed"
    fi

    print_step "Claude Code CLI setup complete"
}

# Main function to run all dev tools
setup_dev_tools() {
    setup_neovim
    setup_podman
    setup_tailscale
    setup_latex
    setup_micromamba
    setup_cli_utilities
    setup_cheat
    setup_claude
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    detect_distro
    setup_dev_tools
fi
