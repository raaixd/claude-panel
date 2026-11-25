#!/bin/sh
# claude-panel toggle (bind it to SUPER + A). The panel is a normal window that stays on its workspace.
#   not open        -> opens on this workspace
#   open here       -> focused: hide it; not focused: focus it
#   open elsewhere  -> jump to it
#   claude-panel.sh quit  -> close it for good (bind to SUPER + SHIFT + A); sessions resume next time
CFG="${CLAUDE_PANEL_CONFIG:-claude-panel}"
CFGDIR="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/$CFG"

# qmltermwidget's compiled-in data paths are wrong on some distros (arrow keys stop working): point it at the real ones
for d in /usr/lib/qt6/qml /usr/lib64/qt6/qml /usr/lib/x86_64-linux-gnu/qt6/qml /usr/lib/aarch64-linux-gnu/qt6/qml; do
  [ -d "$d/QMLTermWidget/kb-layouts" ] && { export KB_LAYOUT_DIR="$d/QMLTermWidget/kb-layouts"; break; }
done
export COLORSCHEMES_DIR="$CFGDIR/schemes"

ipc() { qs ipc -c "$CFG" call claude "$@" >/dev/null 2>&1; }

if [ "${1:-}" = "quit" ]; then
  inst=$(qs list --all 2>/dev/null | grep -B3 "quickshell/$CFG/shell.qml" | awk '/^Instance/{print $2}' | tr -d :)
  [ -n "$inst" ] && qs kill -i "$inst" >/dev/null 2>&1
  exit 0
fi

if ! qs ipc -c "$CFG" show >/dev/null 2>&1; then
  qs -c "$CFG" -n -d >/dev/null 2>&1
  i=0
  while [ $i -lt 20 ]; do sleep 0.15; ipc open && exit 0; i=$((i + 1)); done
  exit 0
fi

win=$(hyprctl clients -j | jq -r '[.[] | select(.title == "Claude Panel")][0] // empty | "\(.address) \(.workspace.id)"')
[ -z "$win" ] && { ipc open; exit 0; }
addr=${win% *}; ws=${win#* }
cur=$(hyprctl activeworkspace -j | jq -r .id)
act=$(hyprctl activewindow -j | jq -r '.address // empty')
if [ "$ws" = "$cur" ] && [ "$act" = "$addr" ]; then
  ipc close
else
  # Hyprland with a Lua config takes Lua here; older versions take the classic dispatcher
  hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" 2>&1 | grep -q error &&
    hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
fi
