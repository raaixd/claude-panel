#!/usr/bin/env python3
"""claude-panel bridge: feeds the panel from Claude Code hooks and session files.

Claude Code calls it for the panel's session only (launch.sh passes --settings, ~/.claude/settings.json is untouched):
  bridge.py hook      hook input on stdin -> one JSON line appended to $RUN/events.jsonl
  bridge.py status    statusLine input on stdin -> $RUN/status.json, then prints your normal status line
The panel calls:
  bridge.py sessions  recent sessions from ~/.claude/projects as JSON
  bridge.py others    Claude sessions running outside the panel (status, last message)
  bridge.py focus PID focus the window that claude process runs in
"""
import json
import os
import subprocess
import sys
import time

RUN = os.environ.get("CLAUDE_PANEL_RUN") or os.path.join(
    os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "claude-panel")
HOME = os.path.expanduser("~")
CLAUDE_DIR = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
STATUSLINE = os.path.join(CLAUDE_DIR, "statusline-command.sh")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
MAX_ROWS = 400
MAX_COL = 240


def clip(s):
    s = str(s)
    return s if len(s) <= MAX_COL else s[:MAX_COL] + "…"


def append(ev):
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    ev["ts"] = int(time.time() * 1000)
    data = (json.dumps(ev, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    fd = os.open(os.path.join(RUN, "events.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, data)  # one O_APPEND write: concurrent hooks never interleave
    finally:
        os.close(fd)


def diff_rows(tool, inp, resp):
    rows, add, rem = [], 0, 0
    hunks = resp.get("structuredPatch") if isinstance(resp, dict) else None
    if hunks:
        for h in hunks:
            o, n = int(h.get("oldStart") or 1), int(h.get("newStart") or 1)
            if rows:
                rows.append({"k": "gap", "n": 0, "t": ""})
            for line in h.get("lines") or []:
                m, t = (line[:1], line[1:]) if line else (" ", "")
                if m == "+":
                    rows.append({"k": "add", "n": n, "t": clip(t)}); n += 1; add += 1
                elif m == "-":
                    rows.append({"k": "del", "n": o, "t": clip(t)}); o += 1; rem += 1
                else:
                    rows.append({"k": "ctx", "n": n, "t": clip(t)}); o += 1; n += 1
    elif tool == "Write":
        for i, t in enumerate(str(inp.get("content") or "").split("\n"), 1):
            rows.append({"k": "add", "n": i, "t": clip(t)}); add += 1
    return rows[:MAX_ROWS], add, rem


def cmd_hook():
    d = json.load(sys.stdin)
    e = d.get("hook_event_name") or ""
    ev = {"e": e}
    if e == "SessionStart":
        ev.update(cwd=d.get("cwd") or "", sid=d.get("session_id") or "", model=d.get("model") or "",
                  src=d.get("source") or "")
    elif e == "UserPromptSubmit":
        ev.update(p=" ".join(str(d.get("prompt") or "").split())[:160])
    elif e == "Notification":
        ev.update(msg=clip(d.get("message") or ""))
    elif e == "PostToolUse":
        tool, inp = d.get("tool_name") or "", d.get("tool_input") or {}
        resp = d.get("tool_response") or {}
        if tool in EDIT_TOOLS:
            path = inp.get("file_path") or inp.get("notebook_path") or ""
            rows, add, rem = diff_rows(tool, inp, resp)
            created = isinstance(resp, dict) and resp.get("type") == "create"
            ev.update(e="edit", path=path, created=created, rows=rows, add=add, rem=rem)
        elif tool == "TodoWrite":
            ev.update(e="todos", todos=[{"t": clip(x.get("content") or ""), "s": x.get("status") or "pending"}
                                        for x in inp.get("todos") or [] if isinstance(x, dict)])
        elif tool == "TaskUpdate":  # new tasks arrive through the TaskCreated hook
            tid = str(inp.get("taskId") or inp.get("id") or "")
            if not tid:
                return
            ev.update(e="task", id=tid, t=clip(inp.get("subject") or ""), s=inp.get("status") or "")
        else:
            return
    elif e in ("TaskCreated", "TaskCompleted"):
        ev.update(e="task", id=str(d.get("task_id") or ""), t=clip(d.get("task_subject") or ""),
                  s="completed" if e == "TaskCompleted" else "pending")
    elif e not in ("Stop", "StopFailure", "SessionEnd", "PreCompact", "PostCompact"):
        return
    append(ev)


def cmd_status():
    raw = sys.stdin.read()
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    tmp = os.path.join(RUN, "status.json.tmp")
    with open(tmp, "w") as f:
        f.write(raw)
    os.replace(tmp, os.path.join(RUN, "status.json"))
    if os.path.exists(STATUSLINE):  # keep your usual status line inside the panel too
        try:
            out = subprocess.run(["bash", STATUSLINE], input=raw, capture_output=True, text=True, timeout=8).stdout
            sys.stdout.write(out)
            return
        except Exception:
            pass
    try:
        d = json.loads(raw)
        print((d.get("model") or {}).get("display_name") or "")
    except Exception:
        pass


def first_prompt(path):
    try:
        with open(path, "rb") as f:
            for i, line in enumerate(f):
                if i > 400:
                    break
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("type") != "user" or o.get("isMeta"):
                    continue
                c = (o.get("message") or {}).get("content")
                if isinstance(c, list):
                    c = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
                c = (c or "").strip()
                if c and not c.startswith("<") and not c.startswith("This session is being continued"):
                    return o.get("cwd") or "", " ".join(c.split())[:120]
    except OSError:
        pass
    return "", ""


def cmd_sessions():
    base = os.path.join(CLAUDE_DIR, "projects")
    files = []
    try:
        for p in os.listdir(base):
            d = os.path.join(base, p)
            if os.path.isdir(d):
                files += [os.path.join(d, n) for n in os.listdir(d) if n.endswith(".jsonl")]
    except OSError:
        pass
    files.sort(key=lambda f: os.path.getmtime(f), reverse=True)
    out = []
    for f in files[:40]:
        cwd, title = first_prompt(f)
        if not title:
            continue
        out.append({"id": os.path.basename(f)[:-6], "cwd": cwd or HOME, "title": title,
                    "mtime": int(os.path.getmtime(f))})
        if len(out) >= 20:
            break
    print(json.dumps(out, ensure_ascii=False))


def last_text(path):
    """last thing Claude said in a transcript (read from the end, cheap)."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 200_000))
            lines = f.read().splitlines()
    except OSError:
        return ""
    for line in reversed(lines):
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") != "assistant":
            continue
        for c in reversed((o.get("message") or {}).get("content") or []):
            if isinstance(c, dict) and c.get("type") == "text" and c.get("text", "").strip():
                return " ".join(c["text"].split())[:200]
    return ""


def is_panel(pid):
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            return b"CLAUDE_PANEL_RUN=" in f.read()
    except OSError:
        return False


def cmd_others():
    """Claude sessions running outside the panel (each running claude registers in ~/.claude/sessions)."""
    base = os.path.join(CLAUDE_DIR, "sessions")
    out = []
    try:
        names = os.listdir(base)
    except OSError:
        names = []
    only = os.environ.get("CLAUDE_PANEL_OTHERS_UNDER")  # optional: list only sessions under this folder
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(base, n)))
            pid = int(d.get("pid") or 0)
            os.kill(pid, 0)
        except Exception:
            continue
        try:  # the pid must still be that claude
            if b"claude" not in open(f"/proc/{pid}/cmdline", "rb").read():
                continue
        except OSError:
            continue
        panel = is_panel(pid)
        if only and not panel and not (d.get("cwd") or "").startswith(os.path.realpath(os.path.expanduser(only))):
            continue
        sid = d.get("sessionId") or ""
        tr = ""
        for p in os.listdir(os.path.join(CLAUDE_DIR, "projects")):
            c = os.path.join(CLAUDE_DIR, "projects", p, sid + ".jsonl")
            if os.path.exists(c):
                tr = c
                break
        title = d.get("name") if d.get("nameSource") == "user" else ""
        if not title and tr:
            title = first_prompt(tr)[1]
        if panel:  # only its name matters to the panel
            out.append({"pid": pid, "sid": sid, "panel": True, "name": d.get("name") if d.get("nameSource") == "user" else ""})
            continue
        out.append({"pid": pid, "sid": sid, "cwd": d.get("cwd") or HOME, "title": title or d.get("name") or "Claude",
                    "status": d.get("status") or "", "since": int((d.get("statusUpdatedAt") or 0) / 1000),
                    "last": last_text(tr) if tr else "", "mtime": int(os.path.getmtime(tr)) if tr else 0})
    out.sort(key=lambda x: -x.get("mtime", 0))
    print(json.dumps(out, ensure_ascii=False))


def cmd_focus():
    """focus the window a claude process runs in (walk up its parents to a Hyprland window)."""
    pid = int(sys.argv[2])
    try:
        wins = {c["pid"]: c["address"] for c in json.loads(subprocess.run(
            ["hyprctl", "clients", "-j"], capture_output=True, text=True, timeout=3).stdout)}
    except Exception:
        return
    while pid > 1:
        if pid in wins:
            # Hyprland with a Lua config takes Lua here (hl.dsp.focus); older ones take the classic dispatcher
            r = subprocess.run(["hyprctl", "dispatch", 'hl.dsp.focus({ window = "address:%s" })' % wins[pid]],
                               capture_output=True, text=True, timeout=3)
            if r.returncode != 0 or "error" in (r.stdout + r.stderr):
                subprocess.run(["hyprctl", "dispatch", "focuswindow", "address:" + wins[pid]], capture_output=True, timeout=3)
            return
        try:
            pid = int(open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[1])
        except Exception:
            return


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    fn = {"hook": cmd_hook, "status": cmd_status, "sessions": cmd_sessions, "others": cmd_others,
          "focus": cmd_focus}.get(cmd)
    if not fn:
        sys.exit("usage: bridge.py hook|status|sessions|others|focus PID")
    try:
        fn()
    except Exception as ex:  # a hook must never break Claude Code
        if cmd != "status":
            print(f"bridge: {ex}", file=sys.stderr)
