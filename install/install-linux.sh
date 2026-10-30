#!/bin/sh
# Registers the audiocompanion:// URL scheme for the current user (no root).
# Changes: copies the launcher to ~/.local/share/audio-companion/,
# writes ~/.local/share/applications/audiocompanion.desktop,
# runs update-desktop-database and xdg-mime default.
# Undo with: ./install-linux.sh --uninstall
set -e
here=$(cd "$(dirname "$0")" && pwd)
dest="$HOME/.local/share/audio-companion"
desk="$HOME/.local/share/applications/audiocompanion.desktop"

if [ "$1" = "--uninstall" ]; then
    rm -rf "$dest" "$desk"
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    echo "Removed."
    exit 0
fi

command -v cvlc >/dev/null || echo "Warning: cvlc not found - install VLC first." >&2
mkdir -p "$dest" "$(dirname "$desk")"
install -m 755 "$here/audiocompanion-launcher.sh" "$dest/audiocompanion-launcher.sh"
cat > "$desk" <<DESK
[Desktop Entry]
Type=Application
Name=Audio Companion VLC launcher
Exec=$dest/audiocompanion-launcher.sh %u
MimeType=x-scheme-handler/audiocompanion;
NoDisplay=true
Terminal=false
DESK
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
xdg-mime default audiocompanion.desktop x-scheme-handler/audiocompanion
echo "Installed. Test: xdg-open audiocompanion://start"
