#!/bin/bash

################################################################################
# Ubuntu 24.04 Setup Script
# Automated setup for a fresh Ubuntu 24.04 installation
# This script installs and configures all essential tools and applications
# Safe to run multiple times - will skip already installed components
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_step() {
    echo -e "${BLUE}==>${NC} ${GREEN}$1${NC}"
}

print_error() {
    echo -e "${RED}ERROR: $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

# Get the directory where this script is located
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        Ubuntu 24.04 Development Setup Script            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Confirm with user
read -p "This will set up your Ubuntu 24.04 system. Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Setup cancelled."
    exit 1
fi

################################################################################
# 1. System Update and Essential Packages
################################################################################

print_step "Updating system packages..."
sudo apt update
sudo apt upgrade -y

print_step "Installing essential build tools and dependencies..."
sudo apt install -y \
    build-essential \
    git \
    git-lfs \
    curl \
    wget \
    unzip \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https

################################################################################
# 2. Zsh and Oh My Zsh Setup
################################################################################

print_step "Installing Zsh..."
sudo apt install -y zsh

print_step "Installing Oh My Zsh..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

print_step "Installing Zsh plugins..."
# zsh-syntax-highlighting
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
        ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
fi

# zsh-autosuggestions
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions \
        ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
fi

print_step "Linking zshrc configuration..."
if [ ! -L "$HOME/.zshrc" ] || [ "$(readlink "$HOME/.zshrc")" != "$DOTFILES_DIR/zshrc" ]; then
    [ -f "$HOME/.zshrc" ] && [ ! -L "$HOME/.zshrc" ] && mv "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%Y%m%d_%H%M%S)"
    ln -sf "$DOTFILES_DIR/zshrc" "$HOME/.zshrc"
fi

################################################################################
# 3. Install JetBrainsMono Nerd Font
################################################################################

print_step "Installing JetBrainsMono Nerd Font..."
if ! fc-list | grep -q "JetBrainsMono Nerd Font"; then
    mkdir -p "$HOME/.local/share/fonts"
    cd /tmp
    wget -q --show-progress https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/JetBrainsMono.zip
    unzip -o JetBrainsMono.zip -d "$HOME/.local/share/fonts/" > /dev/null
    rm JetBrainsMono.zip
    fc-cache -fv > /dev/null
    cd "$DOTFILES_DIR"
else
    print_step "JetBrainsMono Nerd Font is already installed"
fi

################################################################################
# 4. Ghostty Terminal
################################################################################

print_step "Installing Ghostty terminal..."
if ! command -v ghostty &> /dev/null; then
    # Install Ghostty using the community .deb package installer
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh)"
    print_step "Ghostty installed successfully"
else
    print_step "Ghostty is already installed"
fi

print_step "Linking Ghostty configuration..."
mkdir -p "$HOME/.config/ghostty"
if [ ! -L "$HOME/.config/ghostty/config" ] || [ "$(readlink "$HOME/.config/ghostty/config")" != "$DOTFILES_DIR/ghostty/config" ]; then
    [ -f "$HOME/.config/ghostty/config" ] && [ ! -L "$HOME/.config/ghostty/config" ] && mv "$HOME/.config/ghostty/config" "$HOME/.config/ghostty/config.backup.$(date +%Y%m%d_%H%M%S)"
    ln -sf "$DOTFILES_DIR/ghostty/config" "$HOME/.config/ghostty/config"
fi

################################################################################
# 5. Neovim Setup
################################################################################

print_step "Installing Neovim..."
if ! command -v nvim &> /dev/null; then
    sudo snap install --classic nvim
fi

# Install Python support for Neovim
sudo apt install -y python3 python3-pip python3-venv

# Install Node.js (required for many LSP servers)
print_step "Installing Node.js..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt install -y nodejs
fi

# Install ripgrep, fd, and xclip (for Telescope and clipboard support)
print_step "Installing ripgrep, fd-find, and xclip..."
sudo apt install -y ripgrep fd-find xclip

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

################################################################################
# 6. VS Code Installation
################################################################################

print_step "Installing Visual Studio Code..."
if ! command -v code &> /dev/null; then
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
    sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
    sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
    rm -f packages.microsoft.gpg

    sudo apt update
    sudo apt install -y code
fi

print_step "Installing VS Code extensions..."
code --install-extension anthropic.claude-code --force
code --install-extension tyriar.theme-sapphire --force
code --install-extension ms-python.python --force
code --install-extension ms-python.vscode-pylance --force
code --install-extension ms-toolsai.jupyter --force
code --install-extension docker.docker --force
code --install-extension ms-azuretools.vscode-docker --force
code --install-extension james-yu.latex-workshop --force
code --install-extension efoerster.texlab --force
code --install-extension bierner.markdown-mermaid --force
code --install-extension mechatroner.rainbow-csv --force
code --install-extension ms-vscode.makefile-tools --force
code --install-extension ms-vscode.cpptools --force
code --install-extension redhat.vscode-yaml --force

print_step "Removing GitHub Copilot (if installed)..."
code --uninstall-extension GitHub.copilot 2>/dev/null || true

print_step "Configuring VS Code settings..."
mkdir -p "$HOME/.config/Code/User"

# Only set theme if settings.json doesn't exist or doesn't have the theme set
if [ ! -f "$HOME/.config/Code/User/settings.json" ]; then
    # Set Sapphire theme and disable AI features in VS Code settings using Python to ensure valid JSON
    python3 << 'PYEOF'
import json
import os

settings_path = os.path.expanduser("~/.config/Code/User/settings.json")

# Create new settings with Sapphire theme and AI features disabled
settings = {
    "workbench.colorTheme": "Sapphire",
    "claudeCode.preferredLocation": "panel",
    "chat.disableAIFeatures": True,
    "github.copilot.enable": {
        "*": False
    },
    "editor.inlineSuggest.enabled": False,
    "editor.suggest.showInlineCompletions": False,
    "workbench.enableExperiments": False,
    "extensions.experimental.affinity": {
        "github.copilot": 0,
        "github.copilot-chat": 0
    }
}

# Write settings
with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=4)
PYEOF
else
    print_step "VS Code settings already exist, skipping theme configuration"
fi

################################################################################
# 7. GNOME Extensions
################################################################################

print_step "Installing GNOME Extension Manager..."
sudo apt install -y gnome-shell-extension-manager

print_step "Installing chrome-gnome-shell for browser integration..."
sudo apt install -y chrome-gnome-shell

print_step "Installing gnome-extensions-cli for automated extension installation..."
if ! command -v gnome-extensions-cli &> /dev/null; then
    pip3 install --user gnome-extensions-cli --break-system-packages 2>/dev/null || pip3 install --user gnome-extensions-cli
fi

print_step "Disabling Ubuntu Dock to avoid conflicts with Dash to Dock..."
gnome-extensions disable ubuntu-dock@ubuntu.com 2>/dev/null || true

print_step "Installing GNOME extensions..."
# Install extensions using gnome-extensions-cli (will skip if already installed)
~/.local/bin/gext install blur-my-shell@aunetx 2>/dev/null || true
~/.local/bin/gext install dash-to-dock@micxgx.gmail.com 2>/dev/null || true
~/.local/bin/gext install custom-hot-corners-extended@G-dH.github.com 2>/dev/null || true

print_step "Enabling GNOME extensions..."
gnome-extensions enable blur-my-shell@aunetx 2>/dev/null || true
gnome-extensions enable dash-to-dock@micxgx.gmail.com 2>/dev/null || true
gnome-extensions enable custom-hot-corners-extended@G-dH.github.com 2>/dev/null || true

print_step "Configuring Custom Hot Corners..."
# Set bottom-right corner to toggle overview
dconf write /org/gnome/shell/extensions/custom-hot-corners-extended/monitor-0-bottom-right-0/action "'toggle-overview'"

print_step "Configuring Dash to Dock..."
# Set dock height to 100 pixels
gsettings set org.gnome.shell.extensions.dash-to-dock height-fraction 1.0
# Enable autohide when windows maximize (dock-fixed must be false)
gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed false
gsettings set org.gnome.shell.extensions.dash-to-dock autohide true
gsettings set org.gnome.shell.extensions.dash-to-dock intellihide true
# Set max icon size to 48
gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 48
gsettings set org.gnome.shell.extensions.dash-to-dock icon-size-fixed true
# Set background opacity to fixed at 20% with white color
gsettings set org.gnome.shell.extensions.dash-to-dock transparency-mode 'FIXED'
gsettings set org.gnome.shell.extensions.dash-to-dock background-opacity 0.2
gsettings set org.gnome.shell.extensions.dash-to-dock custom-background-color true
gsettings set org.gnome.shell.extensions.dash-to-dock background-color 'rgb(255,255,255)'
# Disable overview on startup (replaces no-overview extension)
gsettings set org.gnome.shell.extensions.dash-to-dock disable-overview-on-startup true

print_step "GNOME extensions installed and enabled"
echo "Note: You may need to restart GNOME Shell (Alt+F2, type 'r', press Enter) or log out for extensions to fully activate"

################################################################################
# 8. Micromamba Setup
################################################################################

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

################################################################################
# 9. Flatpak and Applications
################################################################################

print_step "Setting up Flatpak..."
sudo apt install -y flatpak
sudo apt install -y gnome-software-plugin-flatpak
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

print_step "Installing Flatpak applications..."
flatpak install -y flathub net.ankiweb.Anki

################################################################################
# 12. Additional Development Tools
################################################################################

print_step "Installing Docker..."
if ! command -v docker &> /dev/null; then
    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add user to docker group
    sudo usermod -aG docker "$USER"
fi

print_step "Installing LaTeX..."
sudo apt install -y texlive-latex-extra texlive-fonts-recommended texlive-xetex

print_step "Installing additional utilities..."
sudo apt install -y \
    tmux \
    tree \
    htop \
    btop \
    jq \
    fzf \
    tldr \
    imagemagick

################################################################################
# 12.5. Cheat - Command-line Cheatsheets
################################################################################

print_step "Installing cheat for command-line cheatsheets..."
if ! command -v cheat &> /dev/null; then
    sudo snap install cheat
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

################################################################################
# 13. Additional Applications
################################################################################

print_step "Installing Google Chrome..."
if ! command -v google-chrome &> /dev/null; then
    cd /tmp
    wget -q --show-progress https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    sudo apt install -y ./google-chrome-stable_current_amd64.deb
    rm google-chrome-stable_current_amd64.deb
    cd "$DOTFILES_DIR"
fi

print_step "Installing Microsoft Edge..."
if ! command -v microsoft-edge &> /dev/null; then
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /usr/share/keyrings/microsoft-edge.gpg > /dev/null
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" | sudo tee /etc/apt/sources.list.d/microsoft-edge.list
    sudo apt update
    sudo apt install -y microsoft-edge-stable
fi

print_step "Installing Discord..."
if ! command -v discord &> /dev/null; then
    cd /tmp
    wget -q --show-progress "https://discord.com/api/download?platform=linux&format=deb" -O discord.deb
    sudo apt install -y ./discord.deb
    rm discord.deb
    cd "$DOTFILES_DIR"
fi

print_step "Installing Spotify..."
if ! command -v spotify &> /dev/null; then
    # Import all Spotify GPG keys
    curl -sS https://download.spotify.com/debian/pubkey_6224F9941A8AA6D1.gpg | sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify.gpg
    curl -sS https://download.spotify.com/debian/pubkey_C85668DF69375001.gpg | sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify-2.gpg 2>/dev/null || true
    curl -sS https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.gpg | sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify-3.gpg 2>/dev/null || true
    echo "deb http://repository.spotify.com stable non-free" | sudo tee /etc/apt/sources.list.d/spotify.list
    sudo apt update
    sudo apt install -y spotify-client
fi

print_step "Installing Signal..."
if ! command -v signal-desktop &> /dev/null; then
    wget -qO- https://updates.signal.org/desktop/apt/keys.asc | gpg --dearmor | sudo tee /usr/share/keyrings/signal-desktop-keyring.gpg > /dev/null
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/signal-desktop-keyring.gpg] https://updates.signal.org/desktop/apt xenial main" | sudo tee /etc/apt/sources.list.d/signal-xenial.list
    sudo apt update
    sudo apt install -y signal-desktop
fi

print_step "Installing Obsidian..."
if ! command -v obsidian &> /dev/null; then
    cd /tmp
    # Get the latest version from GitHub releases
    wget -q --show-progress "https://github.com/obsidianmd/obsidian-releases/releases/download/v1.7.7/obsidian_1.7.7_amd64.deb" -O obsidian.deb
    sudo apt install -y ./obsidian.deb
    rm obsidian.deb
    cd "$DOTFILES_DIR"
fi

################################################################################
# 14. Set Wallpaper
################################################################################

print_step "Setting desktop wallpaper..."
# Check for wallpaper in assets folder first, then root directory
if [ -f "$DOTFILES_DIR/assets/wallpaper.jpg" ]; then
    WALLPAPER_PATH="$DOTFILES_DIR/assets/wallpaper.jpg"
elif [ -f "$DOTFILES_DIR/assets/wallpaper.jpeg" ]; then
    WALLPAPER_PATH="$DOTFILES_DIR/assets/wallpaper.jpeg"
elif [ -f "$DOTFILES_DIR/assets/wallpaper.png" ]; then
    WALLPAPER_PATH="$DOTFILES_DIR/assets/wallpaper.png"
elif [ -f "$DOTFILES_DIR/wallpaper.jpg" ]; then
    WALLPAPER_PATH="$DOTFILES_DIR/wallpaper.jpg"
elif [ -f "$DOTFILES_DIR/wallpaper.jpeg" ]; then
    WALLPAPER_PATH="$DOTFILES_DIR/wallpaper.jpeg"
elif [ -f "$DOTFILES_DIR/wallpaper.png" ]; then
    WALLPAPER_PATH="$DOTFILES_DIR/wallpaper.png"
fi

if [ -n "$WALLPAPER_PATH" ] && [ -f "$WALLPAPER_PATH" ]; then
    gsettings set org.gnome.desktop.background picture-uri "file://$WALLPAPER_PATH"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$WALLPAPER_PATH"
    gsettings set org.gnome.desktop.background picture-options "zoom"
    print_step "Wallpaper set successfully"
else
    print_warning "Wallpaper file not found (tried wallpaper.jpg and wallpaper.jpeg)"
fi

################################################################################
# 14.5. Configure Dock Favorites and Desktop
################################################################################

print_step "Configuring dock favorites..."
# Detect the correct Discord desktop file name (could be discord.desktop or discord_discord.desktop for snap)
DISCORD_DESKTOP="discord.desktop"
if [ -f "/var/lib/snapd/desktop/applications/discord_discord.desktop" ]; then
    DISCORD_DESKTOP="discord_discord.desktop"
fi
gsettings set org.gnome.shell favorite-apps "['org.gnome.Nautilus.desktop', 'com.mitchellh.ghostty.desktop', 'google-chrome.desktop', '$DISCORD_DESKTOP', 'spotify.desktop', 'microsoft-edge.desktop', 'code.desktop', 'signal-desktop.desktop', 'obsidian.desktop']"

print_step "Setting accent color to blue..."
# Ubuntu 24.04 uses Yaru theme variants for accent colors
gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-blue'
gsettings set org.gnome.desktop.interface icon-theme 'Yaru-blue'

print_step "Hiding home folder icon from desktop..."
gsettings set org.gnome.shell.extensions.ding show-home false 2>/dev/null || true

print_step "Dock and desktop configured"

################################################################################
# 15. Set Zsh as Default Shell
################################################################################

print_step "Setting Zsh as default shell..."
if [ "$SHELL" != "$(which zsh)" ]; then
    chsh -s "$(which zsh)"
    print_warning "Default shell changed to Zsh. Please log out and log back in for changes to take effect."
fi

################################################################################
# 16. Final Steps
################################################################################

print_step "Running final system update..."
sudo apt update
sudo apt upgrade -y

print_step "Cleaning up..."
sudo apt autoremove -y
sudo apt autoclean

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Setup Complete! 🎉                            ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "  1. REBOOT your system to apply all changes (especially power management)"
echo "  2. Open Neovim and run :checkhealth to verify everything works"
echo "  3. Configure Git with your credentials:"
echo "       git config --global user.name \"Your Name\""
echo "       git config --global user.email \"your.email@example.com\""
echo ""
echo -e "${BLUE}Dotfiles location: $DOTFILES_DIR${NC}"
echo -e "${BLUE}Configuration files are symlinked from this directory${NC}"
echo ""
echo -e "${YELLOW}To reboot now: sudo reboot${NC}"
echo ""
