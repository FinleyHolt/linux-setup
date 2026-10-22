#!/usr/bin/env bash
# GNOME rice, dotfiles, and packages for Arch and Ubuntu.
#
#   ./setup.sh             everything: packages, then dotfiles, then gnome
#   ./setup.sh packages    install the lists in packages/ plus a few direct installs
#   ./setup.sh dotfiles    Oh My Zsh, then symlink zshrc, nvim, ghostty, and bin/
#   ./setup.sh gnome       extensions, settings, wallpaper, and dock favorites
#
# Safe to re-run. A file that a symlink would replace is first moved to
# <file>.bak-<timestamp>.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

EXTENSIONS=(
	blur-my-shell@aunetx
	dash-to-dock@micxgx.gmail.com
	caffeine@patapon.info
	custom-hot-corners-extended@G-dH.github.com
	tiling-assistant@leleat-on-github
)

step() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
	exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# Lines of packages/$1 with comments and blank lines removed.
entries() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$REPO/packages/$1"; }

detect_distro() {
	# shellcheck source=/dev/null
	. /etc/os-release
	case " $ID ${ID_LIKE:-} " in
	*" arch "*) DISTRO=arch ;;
	*" ubuntu "*) DISTRO=ubuntu ;;
	*) die "unsupported distribution '$ID': this script supports Arch and Ubuntu" ;;
	esac
}

################################################################################
# Packages
################################################################################

packages_arch() {
	local pkgs tmp
	mapfile -t pkgs < <(entries arch.txt)
	step "pacman: ${#pkgs[@]} packages"
	sudo pacman -Syu --needed --noconfirm "${pkgs[@]}"

	if ! have yay; then
		step "bootstrapping yay"
		tmp="$(mktemp -d)"
		git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
		(cd "$tmp/yay-bin" && makepkg -si --noconfirm)
		rm -rf "$tmp"
	fi
	mapfile -t pkgs < <(entries aur.txt)
	step "AUR: ${#pkgs[@]} packages"
	yay -S --needed --noconfirm "${pkgs[@]}"
}

packages_ubuntu() {
	local pkgs codename tmp name flags
	codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

	step "apt sources: universe, multiverse, Tailscale"
	sudo add-apt-repository -y universe
	sudo add-apt-repository -y multiverse
	curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$codename.noarmor.gpg" |
		sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
	curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$codename.tailscale-keyring.list" |
		sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null

	mapfile -t pkgs < <(entries ubuntu.txt)
	step "apt: ${#pkgs[@]} packages"
	sudo apt-get update
	sudo apt-get upgrade -y
	sudo apt-get install -y "${pkgs[@]}" tailscale

	step "snaps"
	while read -r name flags; do
		snap list "$name" >/dev/null 2>&1 || sudo snap install "$name" ${flags:+"$flags"}
	done < <(entries snap.txt)

	if ! have google-chrome; then
		step "Google Chrome (the .deb also adds Google's apt repo for updates)"
		tmp="$(mktemp -d)"
		curl -fsSLo "$tmp/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
		sudo apt-get install -y "$tmp/chrome.deb"
		rm -rf "$tmp"
	fi

	if ! have zed && [ ! -x "$HOME/.local/bin/zed" ]; then
		step "Zed"
		curl -fsSL https://zed.dev/install.sh | sh
	fi
	# Ubuntu names fd `fdfind`.
	mkdir -p "$HOME/.local/bin"
	[ -e "$HOME/.local/bin/fd" ] || ln -s "$(command -v fdfind)" "$HOME/.local/bin/fd"

	# `grep >/dev/null`, not `grep -q`: an early exit would SIGPIPE fc-list and
	# fail the pipeline under pipefail, so the font would reinstall every run.
	if ! fc-list | grep 'JetBrainsMono Nerd Font' >/dev/null; then
		step "JetBrainsMono Nerd Font"
		mkdir -p "$HOME/.local/share/fonts/JetBrainsMonoNerd"
		curl -fsSL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz |
			tar -xJ -C "$HOME/.local/share/fonts/JetBrainsMonoNerd"
		fc-cache -f "$HOME/.local/share/fonts"
	fi
}

packages() {
	case "$DISTRO" in
	arch) packages_arch ;;
	ubuntu) packages_ubuntu ;;
	esac

	if [ ! -x "$HOME/.local/bin/micromamba" ]; then
		step "micromamba"
		mkdir -p "$HOME/.local/bin"
		curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest |
			tar -xj -C "$HOME/.local" bin/micromamba
	fi
	# UV_NO_MODIFY_PATH: the zshrc already puts ~/.local/bin on PATH, and the
	# installer would otherwise append to ~/.zshrc, which is this repo's file.
	if ! have uv && [ ! -x "$HOME/.local/bin/uv" ]; then
		step "uv"
		curl -fsSL https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
	fi
	if ! have claude && [ ! -x "$HOME/.local/bin/claude" ]; then
		step "Claude Code"
		curl -fsSL https://claude.ai/install.sh | bash
	fi
	if have rustup && ! rustup toolchain list | grep -v 'no installed toolchains' | grep . >/dev/null; then
		step "Rust stable toolchain"
		rustup default stable
	fi

	step "enabling tailscaled (run 'sudo tailscale up' to log in)"
	sudo systemctl enable --now tailscaled
}

################################################################################
# Dotfiles
################################################################################

# link <path in repo> <destination>: symlink, backing up whatever was there.
link() {
	local src="$REPO/$1" dest="$2"
	[ "$(readlink "$dest" 2>/dev/null)" = "$src" ] && return 0
	mkdir -p "$(dirname "$dest")"
	if [ -e "$dest" ] || [ -L "$dest" ]; then
		mv "$dest" "$dest.bak-$STAMP"
		warn "moved $dest to $dest.bak-$STAMP"
	fi
	ln -s "$src" "$dest"
	step "linked $dest"
}

dotfiles() {
	local custom="$HOME/.oh-my-zsh/custom/plugins" plugin conf zsh_path script

	[ -d "$HOME/.oh-my-zsh" ] ||
		git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
	for plugin in zsh-syntax-highlighting zsh-autosuggestions; do
		[ -d "$custom/$plugin" ] ||
			git clone --depth 1 "https://github.com/zsh-users/$plugin.git" "$custom/$plugin"
	done

	link zshrc "$HOME/.zshrc"
	link nvim "$HOME/.config/nvim"
	link ghostty/config "$HOME/.config/ghostty/config"
	for script in "$REPO"/bin/*; do
		link "bin/${script##*/}" "$HOME/.local/bin/${script##*/}"
	done

	# cheat reads ~/.config/cheat; the Ubuntu snap is confined to its own copy.
	conf="$HOME/.config/cheat/conf.yml"
	if [ "$DISTRO" = ubuntu ]; then
		conf="$HOME/snap/cheat/common/.config/cheat/conf.yml"
	fi
	if [ ! -e "$conf" ]; then
		mkdir -p "$(dirname "$conf")"
		cat >"$conf" <<-EOF
			editor: nvim
			colorize: true
			style: monokai
			pager: less -FRX
			cheatpaths:
			  - name: personal
			    path: $REPO/cheatsheets
			    tags: [ personal ]
			    readonly: false
		EOF
		step "wrote $conf"
	fi

	zsh_path="$(command -v zsh || true)"
	if [ -n "$zsh_path" ] && [ "$(getent passwd "$USER" | cut -d: -f7)" != "$zsh_path" ]; then
		step "making zsh your login shell"
		chsh -s "$zsh_path"
	fi

	if have nvim; then
		step "installing Neovim plugins"
		nvim --headless "+Lazy! sync" +qa || warn "Lazy sync failed; open nvim to retry"
	fi
}

################################################################################
# GNOME
################################################################################

# Add the extensions in "$@" to enabled-extensions and take them out of
# disabled-extensions, which wins when a UUID is in both. Enabling through
# gsettings works before the shell has loaded a new extension, which on
# Wayland only happens at the next login.
enable_extensions() {
	python3 - "$@" <<-'PY'
		import ast, subprocess, sys

		def get(key):
		    out = subprocess.run(["gsettings", "get", "org.gnome.shell", key],
		                         capture_output=True, text=True, check=True).stdout.strip()
		    return [] if out.startswith("@as") else ast.literal_eval(out)

		def put(key, value):
		    subprocess.run(["gsettings", "set", "org.gnome.shell", key, str(value)], check=True)

		want = sys.argv[1:]
		enabled = get("enabled-extensions")
		put("enabled-extensions", enabled + [u for u in want if u not in enabled])
		put("disabled-extensions", [u for u in get("disabled-extensions") if u not in want])
	PY
}

# Set the dock to the first installed .desktop file of each "a.desktop|b.desktop"
# group, so one list covers distro packages and snaps.
set_favorites() {
	local dirs=(/usr/share/applications /var/lib/snapd/desktop/applications "$HOME/.local/share/applications")
	local found=() ids group id dir
	for group in "$@"; do
		IFS='|' read -ra ids <<<"$group"
		for id in "${ids[@]}"; do
			for dir in "${dirs[@]}"; do
				if [ -f "$dir/$id" ]; then
					found+=("'$id'")
					continue 3
				fi
			done
		done
	done
	gsettings set org.gnome.shell favorite-apps "[$(
		IFS=,
		echo "${found[*]}"
	)]"
}

gnome() {
	local shell_major uuid url tmp wallpaper
	have gnome-shell || die "GNOME Shell not found; the gnome step needs a GNOME desktop"

	shell_major="$(gnome-shell --version | awk '{print int($3)}')"
	for uuid in "${EXTENSIONS[@]}"; do
		gnome-extensions info "$uuid" >/dev/null 2>&1 && continue
		if ! url="$(curl -fsS "https://extensions.gnome.org/extension-info/?uuid=$uuid&shell_version=$shell_major" | jq -er .download_url)"; then
			warn "$uuid has no release for GNOME $shell_major; skipped"
			continue
		fi
		step "installing $uuid"
		tmp="$(mktemp --suffix=.zip)"
		curl -fsSLo "$tmp" "https://extensions.gnome.org$url"
		gnome-extensions install --force "$tmp"
		rm -f "$tmp"
	done
	enable_extensions "${EXTENSIONS[@]}"

	step "GNOME settings"
	dconf load / <"$REPO/gnome/settings.ini"
	if [ "$DISTRO" = ubuntu ]; then
		# Ubuntu's own dock fights Dash to Dock, and Yaru carries the accent
		# in the theme name.
		gnome-extensions disable ubuntu-dock@ubuntu.com 2>/dev/null || true
		gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-blue-dark'
		gsettings set org.gnome.desktop.interface icon-theme 'Yaru-blue'
	fi

	wallpaper="$HOME/.local/share/backgrounds/linux-setup.jpg"
	install -D -m 0644 "$REPO/assets/wallpaper.jpg" "$wallpaper"
	gsettings set org.gnome.desktop.background picture-uri "file://$wallpaper"
	gsettings set org.gnome.desktop.background picture-uri-dark "file://$wallpaper"

	set_favorites \
		org.gnome.Nautilus.desktop \
		"com.mitchellh.ghostty.desktop|ghostty_ghostty.desktop" \
		"firefox.desktop|firefox_firefox.desktop" \
		"google-chrome.desktop" \
		"code.desktop|com.microsoft.VSCode.desktop|code_code.desktop" \
		"discord.desktop|discord_discord.desktop" \
		"spotify-launcher.desktop|spotify.desktop|spotify_spotify.desktop" \
		"signal.desktop|signal-desktop.desktop|signal-desktop_signal-desktop.desktop" \
		"obsidian.desktop|obsidian_obsidian.desktop"

	step "GNOME done; log out and back in to load new extensions"
}

################################################################################

main() {
	[ "$EUID" -ne 0 ] || die "run as your user; the script calls sudo where it needs root"
	detect_distro

	case "${1:-all}" in
	all)
		sudo -v
		packages
		dotfiles
		gnome
		;;
	packages)
		sudo -v
		packages
		;;
	dotfiles) dotfiles ;;
	gnome) gnome ;;
	*) die "usage: $0 [all|packages|dotfiles|gnome]" ;;
	esac
}

# Sourcing this file (as a private overlay repo might) only defines functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
