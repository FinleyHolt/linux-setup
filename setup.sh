#!/bin/bash

################################################################################
# Master Setup Script
# Automated setup for fresh Linux installations (Ubuntu/Fedora)
# Supports both full desktop and WSL2 environments
################################################################################

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
source "$SCRIPT_DIR/modules/common.sh"

# Detect distribution early
detect_distro

################################################################################
# Display Banner
################################################################################

echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           Linux Development Setup Script                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "Detected distribution: ${GREEN}$DISTRO $DISTRO_VERSION${NC}"
echo -e "Package manager: ${GREEN}$PKG_MGR${NC}"

if is_wsl; then
    echo -e "Environment: ${YELLOW}WSL2${NC}"
else
    echo -e "Environment: ${GREEN}Native Linux${NC}"
fi

echo ""

################################################################################
# Setup Mode Selection
################################################################################

# Auto-detect WSL2 and offer appropriate defaults
if is_wsl; then
    echo "WSL2 environment detected!"
    echo ""
    echo "Select setup mode:"
    echo "  1) WSL2 Minimal (Recommended) - Shell, Neovim, CLI tools only"
    echo "  2) Full Desktop - Everything including GUI apps (not typical for WSL2)"
    echo "  3) Custom - Choose individual modules"
    echo ""
    read -p "Enter your choice (1-3) [default: 1]: " -n 1 -r SETUP_MODE
    echo
    SETUP_MODE=${SETUP_MODE:-1}
else
    echo "Select setup mode:"
    echo "  1) Full Desktop (Recommended) - Complete setup with GUI apps"
    echo "  2) Server/Minimal - No desktop components, terminal only"
    echo "  3) Custom - Choose individual modules"
    echo ""
    read -p "Enter your choice (1-3) [default: 1]: " -n 1 -r SETUP_MODE
    echo
    SETUP_MODE=${SETUP_MODE:-1}
fi

echo ""
read -p "This will set up your $DISTRO system. Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Setup cancelled."
    exit 1
fi

################################################################################
# Execute Setup Based on Mode
################################################################################

case $SETUP_MODE in
    1)
        # Save SCRIPT_DIR before sourcing modules (modules overwrite SCRIPT_DIR)
        SETUP_DIR="$SCRIPT_DIR"
        if is_wsl; then
            # WSL2 minimal setup
            print_section "Starting WSL2 Minimal Setup"
            source "$SETUP_DIR/modules/wsl.sh"
            setup_wsl
        else
            # Full desktop setup
            print_section "Starting Full Desktop Setup"
            source "$SETUP_DIR/modules/core.sh"
            source "$SETUP_DIR/modules/shell.sh"
            source "$SETUP_DIR/modules/dev-tools.sh"
            source "$SETUP_DIR/modules/desktop.sh"

            setup_core
            setup_shell
            setup_dev_tools
            setup_desktop
        fi
        ;;
    2)
        # Save SCRIPT_DIR before sourcing modules (modules overwrite SCRIPT_DIR)
        SETUP_DIR="$SCRIPT_DIR"
        if is_wsl; then
            # Full desktop on WSL2 (unusual)
            print_section "Starting Full Desktop Setup on WSL2"
            print_warning "Note: This is uncommon for WSL2 environments"
            source "$SETUP_DIR/modules/core.sh"
            source "$SETUP_DIR/modules/shell.sh"
            source "$SETUP_DIR/modules/dev-tools.sh"
            source "$SETUP_DIR/modules/desktop.sh"

            setup_core
            setup_shell
            setup_dev_tools
            setup_desktop
        else
            # Server/minimal setup
            print_section "Starting Server/Minimal Setup"
            source "$SETUP_DIR/modules/core.sh"
            source "$SETUP_DIR/modules/shell.sh"
            source "$SETUP_DIR/modules/dev-tools.sh"

            setup_core
            setup_shell

            # Ask which dev tools to install
            read -p "Install Neovim? (y/n) [default: y] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                setup_neovim
            fi

            read -p "Install Podman? (y/n) [default: y] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                setup_podman
            fi

            read -p "Install CLI utilities? (y/n) [default: y] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                setup_cli_utilities
            fi

            read -p "Install Claude Code CLI? (y/n) [default: y] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                setup_claude
            fi

            read -p "Install Tailscale? (y/n) [default: y] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                setup_tailscale
            fi

            read -p "Install Micromamba? (y/n) [default: n] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                setup_micromamba
            fi
        fi
        ;;
    3)
        # Custom module selection
        print_section "Custom Module Selection"
        # Save SCRIPT_DIR before sourcing modules (modules overwrite SCRIPT_DIR)
        SETUP_DIR="$SCRIPT_DIR"
        source "$SETUP_DIR/modules/core.sh"
        source "$SETUP_DIR/modules/shell.sh"
        source "$SETUP_DIR/modules/dev-tools.sh"

        if ! is_wsl; then
            source "$SETUP_DIR/modules/desktop.sh"
        fi

        # Core is always installed
        setup_core

        read -p "Install Shell configuration (Zsh, dotfiles, fonts)? (y/n) [default: y] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            setup_shell
        fi

        read -p "Install Neovim? (y/n) [default: y] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            setup_neovim
        fi

        read -p "Install Podman? (y/n) [default: y] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            setup_podman
        fi

        read -p "Install Tailscale? (y/n) [default: y] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            setup_tailscale
        fi

        read -p "Install LaTeX? (y/n) [default: n] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            setup_latex
        fi

        read -p "Install Micromamba? (y/n) [default: n] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            setup_micromamba
        fi

        read -p "Install CLI utilities? (y/n) [default: y] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            setup_cli_utilities
        fi

        read -p "Install cheat (command-line cheatsheets)? (y/n) [default: n] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            setup_cheat
        fi

        read -p "Install Claude Code CLI? (y/n) [default: y] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            setup_claude
        fi

        if ! is_wsl; then
            read -p "Install desktop components (GUI apps, GNOME, etc.)? (y/n) [default: n] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                setup_desktop
            fi
        fi
        ;;
    *)
        print_error "Invalid choice. Exiting."
        exit 1
        ;;
esac

################################################################################
# Final Steps
################################################################################

print_section "Final Steps"

print_step "Running final system update..."
pkg_update
pkg_upgrade

print_step "Cleaning up..."
pkg_clean

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Setup Complete! 🎉                            ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"

if is_wsl; then
    echo "  1. Restart your WSL2 session: exit and reopen"
    echo "  2. Open Neovim and run :checkhealth to verify everything works"
    echo "  3. Configure Git with your credentials:"
else
    echo "  1. REBOOT your system to apply all changes"
    echo "  2. Open Neovim and run :checkhealth to verify everything works"
    echo "  3. Configure Git with your credentials:"
fi

echo "       git config --global user.name \"Your Name\""
echo "       git config --global user.email \"your.email@example.com\""
echo ""
echo -e "${BLUE}Dotfiles location: $SCRIPT_DIR${NC}"
echo -e "${BLUE}Configuration files are symlinked from this directory${NC}"
echo ""

if ! is_wsl; then
    echo -e "${YELLOW}To reboot now: sudo reboot${NC}"
    echo ""
fi
