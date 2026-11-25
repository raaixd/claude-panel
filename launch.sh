#!/usr/bin/env bash
# Runs the real Claude Code inside the panel (one call per panel session). Hooks + statusLine come from --settings for THIS session only.
#   launch.sh [--run DIR] [--keep] [claude args...]   (e.g. --resume <id>)
set -u
HERE="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
RUN="${XDG_RUNTIME_DIR:-/tmp}/claude-panel"
# --run DIR: this panel session's own folder (each session in the panel has one)
if [ "${1:-}" = "--run" ]; then RUN="$2"; shift 2; fi
export CLAUDE_PANEL_RUN="$RUN"
mkdir -p "$RUN" && chmod 700 "$RUN"

B="python3 -I $HERE/bridge.py"
python3 - "$B" > "$RUN/settings.json" <<'EOF'
import json, sys
b = sys.argv[1]
hook = lambda sync: [{"hooks": [{"type": "command", "command": b + " hook", "timeout": 5 if sync else 10,
                                 **({} if sync else {"async": True})}]}]
h = {e: hook(False) for e in ["SessionStart", "UserPromptSubmit", "TaskCreated", "TaskCompleted", "PreCompact", "PostCompact"]}
h.update({e: hook(True) for e in ["Stop", "StopFailure", "Notification", "SessionEnd"]})
h["PostToolUse"] = [{"matcher": "Edit|Write|MultiEdit|NotebookEdit|TodoWrite|TaskUpdate",
                     "hooks": hook(False)[0]["hooks"]}]
print(json.dumps({"hooks": h, "statusLine": {"type": "command", "command": b + " status", "refreshInterval": 30}}))
EOF

# if the panel was started from inside another Claude Code session, drop that session's markers
unset CLAUDECODE CLAUDE_PID CLAUDE_EFFORT CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION \
      CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN

# --keep (from the panel's model/effort switch): same conversation, keep the panel's record
if [ "${1:-}" = "--keep" ]; then
    shift
    # a session with no messages has no transcript yet and cannot be resumed: start fresh instead
    if [ "${1:-}" = "--resume" ] && ! ls "$HOME"/.claude/projects/*/"${2:-x}.jsonl" >/dev/null 2>&1; then shift 2; fi
else
    : > "$RUN/events.jsonl"     # new session = fresh panel record
    echo "{}" > "$RUN/status.json"
fi
# does Claude still ask "do you trust this folder?" here? (your home folder: every time) -> the panel answers Yes
python3 - "$PWD" > "$RUN/trust.json" <<'EOF2'
import json, os, sys
d = os.path.realpath(sys.argv[1]); home = os.path.expanduser("~")
try:
    p = json.load(open(os.path.join(home, ".claude.json"))).get("projects", {})
except Exception:
    p = {}
ok = False
x = d
while True:  # trust given to a parent folder covers this one (never the home folder itself)
    if x != home and p.get(x, {}).get("hasTrustDialogAccepted"):
        ok = True; break
    if x in ("/", home) or not x: break
    x = os.path.dirname(x)
print(json.dumps({"needs": not ok, "dir": d}))
EOF2
export TERM=xterm-256color COLORTERM=truecolor
exec claude --settings "$RUN/settings.json" "$@"
