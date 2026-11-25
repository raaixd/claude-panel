#!/bin/sh
# Install claude-panel for the current user.
#   ./install.sh          copy the panel to ~/.config/quickshell/claude-panel and the toggle to ~/.local/bin
#   ./install.sh --bind   also add SUPER + A / SUPER + SHIFT + A to your Caelestia Hyprland user config
#   ./install.sh --remove remove the panel files (not your Claude sessions)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
CFGDIR="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/claude-panel"
BIN="$HOME/.local/bin/claude-panel"

if [ "${1:-}" = "--remove" ]; then
  "$BIN" quit 2>/dev/null || true
  rm -rf "$CFGDIR" "$BIN"
  echo "Removed. Delete the SUPER + A lines from your Hyprland config yourself if you added them."
  exit 0
fi

missing=""
for c in qs claude python3 jq hyprctl; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
found=""
for d in /usr/lib/qt6/qml /usr/lib64/qt6/qml /usr/lib/x86_64-linux-gnu/qt6/qml /usr/lib/aarch64-linux-gnu/qt6/qml; do
  [ -d "$d/QMLTermWidget" ] && found=1
done
[ -z "$found" ] && missing="$missing qmltermwidget"
if [ -n "$missing" ]; then
  echo "Missing:$missing"
  echo "On Arch: sudo pacman -S --needed qmltermwidget jq   (quickshell and claude-code: from the AUR / npm)"
  exit 1
fi

mkdir -p "$CFGDIR/schemes" "$(dirname "$BIN")"
cp "$HERE"/shell.qml "$HERE"/Session.qml "$HERE"/Term.qml "$HERE"/bridge.py "$HERE"/launch.sh "$CFGDIR/"
cp "$HERE"/schemes/*.colorscheme "$CFGDIR/schemes/"
chmod +x "$CFGDIR/launch.sh" "$CFGDIR/bridge.py"
cp "$HERE/scripts/claude-panel.sh" "$BIN"; chmod +x "$BIN"
echo "Installed to $CFGDIR and $BIN"

if [ "${1:-}" = "--bind" ]; then
  LUA="$HOME/.config/caelestia/hypr-user.lua"; CONF="$HOME/.config/caelestia/hypr-user.conf"
  if [ -f "$LUA" ]; then
    grep -q 'claude-panel' "$LUA" || cat >> "$LUA" <<'B'

-- claude-panel: SUPER + A show / jump / hide, SUPER + SHIFT + A close for good
hl.bind("SUPER + A", hl.dsp.exec_cmd(os.getenv("HOME") .. "/.local/bin/claude-panel"))
hl.bind("SUPER + SHIFT + A", hl.dsp.exec_cmd(os.getenv("HOME") .. "/.local/bin/claude-panel quit"))
B
    echo "Added the keys to $LUA"
  elif [ -f "$CONF" ]; then
    grep -q 'claude-panel' "$CONF" || cat >> "$CONF" <<'B'

# claude-panel: SUPER + A show / jump / hide, SUPER + SHIFT + A close for good
bind = SUPER, A, exec, ~/.local/bin/claude-panel
bind = SUPER SHIFT, A, exec, ~/.local/bin/claude-panel quit
B
    echo "Added the keys to $CONF"
  else
    echo "No Caelestia user config found: add the binds yourself (see README)."
  fi
fi
echo "Check SUPER + A is not already used by something else in your setup."
