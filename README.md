# claude-panel

A Claude Code control panel for **Hyprland + Quickshell**, made on and for the
[Caelestia](https://github.com/caelestia-dots/shell) desktop (works on any Hyprland setup with Quickshell).

One window that runs and tracks all your Claude Code sessions:

- **Real Claude Code sessions, several at once.** Each panel session is the actual `claude` CLI in a terminal;
  the ones you are not looking at keep running. Switch with a click or `Alt+1..9`.
- **Sessions in other windows.** Claude sessions you started in normal terminals are listed with their status
  (working / idle) and how long ago they last did something. Click one to jump to its window.
- **Per session:** model (Opus / Sonnet / Fable / Haiku) and effort switch (relaunches the same conversation with
  `--model` / `--effort`, your saved default is never changed), context use, Claude's task list,
  and every file it changed with a diff view.
- **Plan usage** (5-hour and weekly), red from 80%.
- **Notifications** when a session finishes or needs you and you are not looking at it.
- **History:** resume any past conversation in the panel (or jump to it if it is open somewhere else).
- **Survives restarts:** open sessions stay in the list and resume when you click them.
- A short black boot screen that says hi.
- Answers Claude's "do you trust this folder?" question for you when it opens in a folder that is not trusted yet
  (your home folder always asks). Remove `onNowMsChanged` in `Session.qml` if you don't want that.

The panel is a normal window: it stays on the workspace where you opened it.

| Key | What it does |
|---|---|
| `SUPER + A` | open it here · hide it (if focused) · jump to it (if it is on another workspace) |
| `SUPER + SHIFT + A` | close it for good (its sessions end, and resume next time you open it) |
| `Alt + 1..9` (inside) | switch session |
| `Ctrl + Shift + C / V` (inside) | copy / paste in the terminal |

## Needs

- Hyprland (Lua or classic config), [Quickshell](https://quickshell.org) (`qs`)
- `qmltermwidget` (Qt 6 build; Arch: `sudo pacman -S qmltermwidget`)
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude`) 2.1 or newer
- `python3`, `jq`
- Fonts: Inter, JetBrainsMono Nerd Font, Material Symbols Rounded (Caelestia ships all three)

## Install

```sh
git clone https://github.com/raaixd/claude-panel
cd claude-panel
./install.sh --bind      # --bind adds the two keys to ~/.config/caelestia/hypr-user.lua (or .conf)
```

Without Caelestia, add the keys yourself:

```lua
-- Hyprland Lua config
hl.bind("SUPER + A", hl.dsp.exec_cmd(os.getenv("HOME") .. "/.local/bin/claude-panel"))
hl.bind("SUPER + SHIFT + A", hl.dsp.exec_cmd(os.getenv("HOME") .. "/.local/bin/claude-panel quit"))
```

```ini
# hyprland.conf
bind = SUPER, A, exec, ~/.local/bin/claude-panel
bind = SUPER SHIFT, A, exec, ~/.local/bin/claude-panel quit
```

Optional, for a frosted look behind the window: enable blur for transparent windows in your Hyprland decoration settings.
The greeting uses your login name; set `CLAUDE_PANEL_NAME` to change it.

Uninstall: `./install.sh --remove`.

## How it works

- `launch.sh` starts `claude` with `--settings <file>` that adds hooks and a status line **for that session only**.
  Your `~/.claude/settings.json` is never touched.
- `bridge.py` is what those hooks call: it appends events (prompt sent, stopped, needs you, file edits with diffs,
  tasks) to `$XDG_RUNTIME_DIR/claude-panel/s/<session>/events.jsonl` and writes the status line data to
  `status.json`. If you have `~/.claude/statusline-command.sh`, it still runs, so your own status line shows too.
- Sessions in other windows come from `~/.claude/sessions/<pid>.json`, which Claude Code keeps for every running session.
- The open-session list is saved in `~/.local/state/claude-panel/sessions.json`.

Nothing leaves your machine; there is no network code.

## Notes

- Editing the panel's QML files makes Quickshell reload it, which restarts the Claude sessions inside it
  (they resume when you click them).
- A panel session uses about as much memory as Claude Code in a terminal (~250 MB); the panel itself is ~200 MB.
- `schemes/DarkPastels.colorscheme` is a muted black terminal palette kept under a stock name, because qmltermwidget
  does not pick up new scheme names from `COLORSCHEMES_DIR`.

## License

MIT
