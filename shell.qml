// claude-panel: a Claude Code orchestrator panel for Quickshell + Hyprland.
// Left: sessions in the panel, Claude sessions running in other windows, history.
// Middle: the selected session's real `claude` terminal (+ diff tabs). Right: its model/effort, usage, tasks, files.
// Runs as its own Quickshell config, so it can never take the bar or Caelestia down with it.
// Toggle: SUPER + A (scripts/claude-panel.sh), close for good: SUPER + SHIFT + A. In the panel: Alt+1..9 switch session.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // ---------- look: monochrome. Black glass, white type, greys for hierarchy. No color except diff +/- ----------
    readonly property string textFont: "Inter"
    readonly property string monoFont: "JetBrainsMono Nerd Font"
    readonly property string iconFont: "Material Symbols Rounded"
    readonly property color accent: "#f2f2f2"          // = white: the only emphasis
    readonly property color cText: "#ededed"
    readonly property color cText2: "#a0a0a0"
    readonly property color cMuted: "#626262"
    readonly property color cFaint: "#3c3c3c"
    readonly property color cLine: Qt.rgba(1, 1, 1, 0.07)
    readonly property color cHover: Qt.rgba(1, 1, 1, 0.04)
    readonly property color cSel: Qt.rgba(1, 1, 1, 0.075)
    readonly property color cHigh: cSel
    readonly property color cSurf: cHover
    readonly property color cAdd: "#8fae94"
    readonly property color cDel: "#b88a8a"
    function a(c, x) { return Qt.rgba(c.r, c.g, c.b, x); }

    // ---------- state ----------
    property bool shown: false
    property bool greeted: false
    readonly property string home: Quickshell.env("HOME")
    // the boot screen says "hi <name>": CLAUDE_PANEL_NAME, else your login name
    readonly property string greetName: (Quickshell.env("CLAUDE_PANEL_NAME") || Quickshell.env("USER") || "there").toLowerCase()
    readonly property string runDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/claude-panel"
    readonly property string stateFile: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/claude-panel/sessions.json"
    readonly property string bridge: Qt.resolvedUrl("bridge.py").toString().replace("file://", "")

    property string curKey: ""
    property var items: ({})          // key -> Session
    property int regV: 0
    readonly property var cur: { regV; return items[curKey] || null; }
    property string current: ""       // "" = terminal, else a diff tab (path)
    property var tabs: []
    property var limits: ({})         // plan usage (same for every session)
    property var others: []           // Claude sessions in other windows
    property var history: []
    property string page: "sessions"  // sessions | history
    property bool newForm: false
    property int now: Math.floor(Date.now() / 1000)
    Timer { interval: 15000; repeat: true; running: root.shown; triggeredOnStart: true; onTriggered: root.now = Math.floor(Date.now() / 1000) }

    ListModel { id: slots }           // {key, cwd, sid, title, mdl, eff}; a ListModel so adding one never restarts the others

    function reg(k, it) { items[k] = it; regV++; }
    function unreg(k) { delete items[k]; regV++; }
    function toggle() { shown ? close() : open(); }
    function open() {
        now = Math.floor(Date.now() / 1000); shown = true; othersProc.running = true;
        if (!greeted) { greeted = true; boot.play(); }
        if (slots.count === 0) newSession(home, "");
        else if (!cur) select(slots.get(0).key);
        else if (cur.started) refreshT.restart(); else cur.ensureStarted();
    }
    Timer { id: refreshT; interval: 120; onTriggered: if (root.cur) { root.cur.refresh(); root.cur.focusTerm(); } }
    function close() { shown = false; newForm = false; }
    onShownChanged: if (shown) Qt.callLater(() => { refreshT.restart(); })   // the terminal needs a redraw after the window maps
    function select(k) {
        if (curKey !== k) { tabs = []; current = ""; }
        curKey = k; newForm = false; save();
        Qt.callLater(() => { if (root.cur) root.cur.focusTerm(); });
    }
    function newSession(cwd, model, resumeSid, title) {
        const k = Date.now().toString(36) + Math.floor(Math.random() * 1000);
        slots.append({ key: k, cwd: cwd || home, sid: resumeSid || "", title: title || "", mdl: model || "", eff: "" });
        select(k);
    }
    function closeSession(k) {
        let i = 0; for (; i < slots.count; i++) if (slots.get(i).key === k) break;
        if (i >= slots.count) return;
        slots.remove(i);        // destroys its terminal: Claude gets a hang-up and exits
        if (curKey === k) { curKey = ""; tabs = []; current = ""; if (slots.count) select(slots.get(Math.min(i, slots.count - 1)).key); }
        save();
    }
    function hotkey(n) { if (n < slots.count) select(slots.get(n).key); }
    function focusOther(pid) { Quickshell.execDetached(["python3", "-I", bridge, "focus", String(pid)]); close(); }
    function openHistory(h) {
        for (let i = 0; i < slots.count; i++) if (items[slots.get(i).key] && items[slots.get(i).key].sid === h.id) { select(slots.get(i).key); page = "sessions"; return; }
        const o = others.find(x => x.sid === h.id);
        if (o) { focusOther(o.pid); return; }          // it is open in another window: go there
        newSession(h.cwd, "", h.id, h.title); page = "sessions";
    }
    function notify(it, kind) {
        if (shown && it.key === curKey) return;
        const t = it.title || "Claude";
        Quickshell.execDetached(["notify-send", "-a", "Claude", "-i", "dialog-information",
            kind === "done" ? "Claude is done" : "Claude needs you", (kind === "done" ? "" : (it.note ? it.note + "\n" : "")) + t.slice(0, 90)]);
    }

    // ---------- open sessions survive a restart of the panel (they resume when you open them) ----------
    function save() { saveT.restart(); }
    Timer {
        id: saveT; interval: 400
        onTriggered: {
            let arr = [];
            for (let i = 0; i < slots.count; i++) {
                const r = slots.get(i), it = root.items[r.key];
                arr.push(it ? { key: r.key, cwd: it.cwd, sid: it.talked || !it.started ? it.sid : "", title: it.title, model: it.selModel, effort: it.selEffort }
                            : { key: r.key, cwd: r.cwd, sid: r.sid, title: r.title, model: r.mdl, effort: r.eff });
            }
            stateView.setText(JSON.stringify({ cur: root.curKey, slots: arr }, null, 1));
        }
    }
    FileView { id: stateView; path: root.stateFile; blockLoading: true; atomicWrites: true }
    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", stateFile.replace(/\/[^/]*$/, "")]);
        try {
            const st = JSON.parse(stateView.text());
            for (const r of st.slots || []) slots.append({ key: r.key, cwd: r.cwd || home, sid: r.sid || "", title: r.title || "", mdl: r.model || "", eff: r.effort || "" });
            if (st.cur) curKey = st.cur;
        } catch (x) { }
    }

    Process {
        id: othersProc
        command: ["python3", "-I", root.bridge, "others"]
        stdout: StdioCollector { onStreamFinished: { try { root.others = JSON.parse(text); } catch (x) { } } }
    }
    Timer { interval: root.shown ? 3000 : 20000; repeat: true; running: true; onTriggered: othersProc.running = true }
    Process {
        id: histProc
        command: ["python3", "-I", root.bridge, "sessions"]
        stdout: StdioCollector { onStreamFinished: { try { root.history = JSON.parse(text); } catch (x) { } } }
    }
    Process {
        id: dirCheck
        property string dir: ""
        property string model: ""
        command: ["test", "-d", dir]
        onExited: (code) => { if (code === 0) root.newSession(dir, model); else root.formError = "That folder doesn't exist"; }
    }
    property string formError: ""
    function expand(p) { p = String(p).trim(); if (p === "" || p === "~") return home; if (p.startsWith("~/")) return home + p.slice(1); return p.replace(/\/+$/, ""); }
    function tilde(p) { p = String(p); return p.startsWith(home) ? "~" + p.slice(home.length) : p; }

    IpcHandler {
        target: "claude"
        function toggle(): void { root.toggle(); }
        function open(): void { root.open(); }
        function close(): void { root.close(); }
        function newSession(cwd: string): void { root.newSession(root.expand(cwd), ""); }
        function select(n: int): void { root.hotkey(n); }
        function closeCurrent(): void { if (root.cur) root.closeSession(root.curKey); }
        function model(id: string): void { if (root.cur) { root.cur.selModel = id; root.cur.relaunch(); } }
        function effort(level: string): void { if (root.cur) { root.cur.selEffort = level; root.cur.relaunch(); } }
        function text(s: string): void { if (root.cur && root.cur.term) root.cur.term.send(s); }
        function key(name: string): void { const m = { left: Qt.Key_Left, up: Qt.Key_Up, down: Qt.Key_Down, back: Qt.Key_Backspace, tab: Qt.Key_Tab, esc: Qt.Key_Escape, enter: Qt.Key_Return }; if (root.cur && root.cur.term) root.cur.term.key(m[name]); }
        function state(): string {
            let l = [];
            for (let i = 0; i < slots.count; i++) { const it = root.items[slots.get(i).key]; if (it) l.push({ key: it.key, sid: it.sid, live: it.sessionLive, started: it.started, act: it.activity, title: it.title, model: it.modelName, cwd: it.cwd }); }
            return JSON.stringify({ cur: root.curKey, sessions: l, others: root.others.length });
        }
    }

    // ---------- derived ----------
    readonly property int nWorking: { regV; let n = 0; for (const k in items) if (items[k].activity === "working") n++; return n + othersU.filter(o => o.status === "busy" || o.status === "shell").length; }
    readonly property int nWaiting: { regV; let n = 0; for (const k in items) if (items[k].activity === "waiting") n++; return n; }
    function lim(k) { return (limits || {})[k] || null; }
    function fmtTok(n) { n = Number(n) || 0; return n >= 1000 ? (n / 1000).toFixed(n >= 100000 ? 0 : 1) + "k" : String(n); }
    function fmtReset(v) {
        if (v == null) return "";
        const t = typeof v === "number" ? v : Math.floor(Date.parse(v) / 1000);
        if (!t) return "";
        const d = new Date(t * 1000), left = t - now;
        const hm = Qt.formatTime(d, "h:mm ap");
        if (left <= 0) return "Resetting";
        if (left < 86400) return "Resets in " + (left >= 3600 ? Math.floor(left / 3600) + "h " : "") + Math.floor(left % 3600 / 60) + "m";
        return "Resets " + Qt.formatDate(d, "ddd") + " " + hm;
    }
    function base(p) { return String(p).split("/").pop(); }
    function shortDir(p) { let d = tilde(String(p).split("/").slice(0, -1).join("/")); return d.length > 40 ? "…" + d.slice(-39) : d; }
    function ago(t) { const s = now - t; return s < 60 ? "now" : s < 3600 ? Math.floor(s / 60) + "m" : s < 86400 ? Math.floor(s / 3600) + "h" : Math.floor(s / 86400) + "d"; }
    function shortModel(m) { return m ? m.replace(/^claude-/, "").replace(/^./, c => c.toUpperCase()).replace(/-(\d+)-(\d+)$/, " $1.$2") : ""; }
    // unique by session id (a resumed conversation can be registered twice)
    readonly property var othersU: { let seen = {}, out = []; for (const o of others) { if (o.panel || seen[o.sid]) continue; seen[o.sid] = 1; out.push(o); } return out; }
    // names you gave sessions (Claude's /rename), for sessions in the panel: sid -> name
    readonly property var names: { let m = {}; for (const o of others) if (o.panel && o.name) m[o.sid] = o.name; return m; }
    function titleOf(it, fallback) { return (it && it.sid && names[it.sid]) || (it && it.title) || fallback || "New session"; }

    // ---------- parts ----------
    component Ic: Text { font.family: root.iconFont; font.pixelSize: 16; color: root.cText2; verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter }
    component T: Text { font.family: root.textFont; font.pixelSize: 13; color: root.cText; elide: Text.ElideRight; verticalAlignment: Text.AlignVCenter; renderType: Text.NativeRendering }
    component Label: Text { font.family: root.textFont; font.pixelSize: 11; font.weight: Font.Medium; color: root.cMuted; renderType: Text.NativeRendering }
    component Rule: Rectangle { implicitHeight: 1; color: root.cLine }
    component Hover: MouseArea { hoverEnabled: true; cursorShape: Qt.PointingHandCursor; anchors.fill: parent }
    readonly property color cHot: "#e5534b"           // usage at 80% or more
    component Bar: Item {
        property real v: 0
        property color c: root.accent
        implicitHeight: 2
        Rectangle { anchors.fill: parent; color: Qt.rgba(1, 1, 1, 0.08) }
        Rectangle { width: parent.width * Math.max(0, Math.min(1, v)); height: parent.height; color: parent.c
                    Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } } }
    }
    // status: working = solid white, breathing; needs you = white ring; idle = dim
    component Dot: Item {
        property string act: "idle"
        property bool dim: false
        width: 8; height: 8
        Rectangle {
            anchors.centerIn: parent; width: 6; height: 6; radius: 3
            color: act === "waiting" ? "transparent" : act === "working" ? root.accent : root.cFaint
            border.width: act === "waiting" ? 1.5 : 0; border.color: root.accent
            opacity: parent.dim ? 0.4 : 1
            SequentialAnimation on opacity { running: act === "working" && root.shown; loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 900; easing.type: Easing.InOutSine } NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine } }
        }
    }
    // segmented option: selected = white with black text
    component Opt: Rectangle {
        property bool on: false
        property string label: ""
        signal clicked()
        height: 28; radius: 7
        color: on ? root.accent : (oh.containsMouse && enabled ? root.cHover : "transparent")
        border.width: on ? 0 : 1; border.color: root.cLine
        Behavior on color { ColorAnimation { duration: 120 } }
        T { anchors.centerIn: parent; text: parent.label; font.pixelSize: 12; font.weight: parent.on ? Font.DemiBold : Font.Normal; color: parent.on ? "black" : root.cText2 }
        Hover { id: oh; onClicked: parent.clicked() }
    }
    component Btn: Rectangle {
        property string label: ""
        property string icon: ""
        property bool primary: false
        signal clicked()
        implicitWidth: br.implicitWidth + 24; height: 30; radius: 8
        color: primary ? (bh.containsMouse ? "white" : root.accent) : (bh.containsMouse ? root.cSel : root.cHover)
        RowLayout { id: br; anchors.centerIn: parent; spacing: 6
            Ic { visible: parent.parent.icon !== ""; text: parent.parent.icon; font.pixelSize: 15; color: parent.parent.primary ? "black" : root.cText }
            T { text: parent.parent.label; font.pixelSize: 12; font.weight: Font.Medium; color: parent.parent.primary ? "black" : root.cText } }
        Hover { id: bh; onClicked: parent.clicked() }
    }
    component ToolTipBox: Rectangle {
        property string text: ""
        width: 360; height: ttt.implicitHeight + 22; radius: 9; z: 100
        color: "#111111"; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
        Text { id: ttt; anchors.fill: parent; anchors.margins: 11; text: parent.text; wrapMode: Text.Wrap; maximumLineCount: 6; elide: Text.ElideRight
               color: root.cText2; font.family: root.textFont; font.pixelSize: 13; lineHeight: 1.15; renderType: Text.NativeRendering }
    }

    // ---------- window ----------
    // A normal window (not an overlay): it lives on one workspace, so Super+number leaves it there and comes back to it.
    // Hyprland tiles it, rounds its corners and blurs behind it. Super+A: show here / jump to it / hide (claude-panel.sh).
    FloatingWindow {
        id: win
        visible: root.shown
        title: "Claude Panel"
        color: "transparent"
        implicitWidth: 1760; implicitHeight: 1080

        Rectangle {
            id: card
            anchors.fill: parent
            color: Qt.rgba(0.03, 0.03, 0.03, 0.82)

            RowLayout {
                anchors.fill: parent; spacing: 0

                // ===== left: sessions =====
                Item {
                    Layout.preferredWidth: 300; Layout.fillHeight: true; z: 2
                    ColumnLayout {
                        anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 14; anchors.topMargin: 20; anchors.bottomMargin: 16; spacing: 0

                        RowLayout {
                            Layout.fillWidth: true; Layout.bottomMargin: 18; spacing: 10
                            T { text: "Claude"; font.pixelSize: 15; font.weight: Font.DemiBold; font.letterSpacing: -0.2 }
                            T { Layout.fillWidth: true; font.pixelSize: 12; color: root.cMuted
                                text: [root.nWorking ? root.nWorking + " working" : "", root.nWaiting ? root.nWaiting + " waiting" : ""].filter(x => x).join("  ·  ") }
                            Rectangle {
                                width: 26; height: 26; radius: 7; color: hb.containsMouse || root.page === "history" ? root.cSel : "transparent"
                                Ic { anchors.centerIn: parent; text: root.page === "history" ? "close" : "history"; color: root.page === "history" ? root.cText : root.cText2 }
                                Hover { id: hb; onClicked: { root.page = root.page === "history" ? "sessions" : "history"; if (root.page === "history") histProc.running = true; } }
                            }
                        }

                        // new session (expands into a small form)
                        Rectangle {
                            Layout.fillWidth: true; Layout.preferredHeight: root.newForm ? form.implicitHeight + 28 : 36; radius: 9
                            color: root.newForm ? Qt.rgba(1, 1, 1, 0.03) : (nh.containsMouse ? root.cSel : root.cHover)
                            border.width: 1; border.color: root.newForm ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                            clip: true
                            RowLayout { visible: !root.newForm; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 8
                                Ic { text: "add"; color: root.cText }
                                T { text: "New session"; font.pixelSize: 13; Layout.fillWidth: true } }
                            Hover { id: nh; visible: !root.newForm
                                onClicked: { root.newForm = true; root.formError = ""; dirIn.text = root.tilde(root.cur ? root.cur.cwd : root.home); form.model = ""; histProc.running = true; Qt.callLater(() => { dirIn.forceActiveFocus(); dirIn.selectAll(); }); } }
                            ColumnLayout {
                                id: form
                                property string model: ""
                                visible: root.newForm
                                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14; spacing: 8
                                Label { text: "Folder" }
                                Rectangle {
                                    Layout.fillWidth: true; height: 32; radius: 7; color: "black"; border.width: 1; border.color: dirIn.activeFocus ? Qt.rgba(1, 1, 1, 0.25) : root.cLine
                                    TextInput {
                                        id: dirIn; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; verticalAlignment: Text.AlignVCenter
                                        color: root.cText; font.family: root.monoFont; font.pixelSize: 12; selectByMouse: true; clip: true
                                        selectionColor: Qt.rgba(1, 1, 1, 0.25); selectedTextColor: "white"
                                        onAccepted: startBtn.go()
                                        Keys.onEscapePressed: { root.newForm = false; if (root.cur) root.cur.focusTerm(); }
                                    }
                                }
                                Flow {   // recent folders
                                    Layout.fillWidth: true; spacing: 4
                                    Repeater {
                                        model: { let seen = {}, out = []; for (const h of root.history) { if (!seen[h.cwd] && out.length < 6) { seen[h.cwd] = 1; out.push(h.cwd); } } return out; }
                                        Rectangle { width: fl.implicitWidth + 14; height: 22; radius: 6; color: fh.containsMouse ? root.cSel : root.cHover
                                            T { id: fl; anchors.centerIn: parent; text: root.tilde(modelData); font.family: root.monoFont; font.pixelSize: 10; color: root.cText2 }
                                            Hover { id: fh; onClicked: dirIn.text = root.tilde(modelData) } }
                                    }
                                }
                                Label { text: "Model"; Layout.topMargin: 4 }
                                GridLayout {
                                    columns: 3; Layout.fillWidth: true; columnSpacing: 4; rowSpacing: 4
                                    Repeater {
                                        model: [["Default", ""], ["Opus", "claude-opus-5-5"], ["Sonnet", "claude-sonnet-5-5"], ["Fable", "claude-fable-5-2"], ["Haiku", "claude-haiku-5-5"]]
                                        Opt { Layout.fillWidth: true; height: 26; label: modelData[0]; on: form.model === modelData[1]; onClicked: form.model = modelData[1] }
                                    }
                                }
                                T { visible: root.formError !== ""; text: root.formError; color: root.cDel; font.pixelSize: 11 }
                                RowLayout {
                                    Layout.fillWidth: true; Layout.topMargin: 4; spacing: 6
                                    Btn { Layout.fillWidth: true; label: "Cancel"; onClicked: { root.newForm = false; if (root.cur) root.cur.focusTerm(); } }
                                    Btn { id: startBtn; Layout.fillWidth: true; label: "Start"; primary: true
                                        function go() { root.formError = ""; dirCheck.dir = root.expand(dirIn.text); dirCheck.model = form.model; dirCheck.running = true; }
                                        onClicked: go() }
                                }
                            }
                        }

                        // sessions: in this panel + in other windows
                        Flickable {
                            visible: root.page === "sessions"
                            Layout.fillWidth: true; Layout.fillHeight: true; Layout.topMargin: 22; clip: true
                            contentHeight: scol.implicitHeight; boundsBehavior: Flickable.StopAtBounds
                            ColumnLayout {
                                id: scol; width: parent.width; spacing: 2
                                Label { text: "Sessions"; Layout.leftMargin: 10; Layout.bottomMargin: 6 }
                                T { visible: slots.count === 0; text: "None open"; color: root.cMuted; font.pixelSize: 13; Layout.leftMargin: 10 }
                                Repeater {
                                    model: slots
                                    Rectangle {
                                        id: row
                                        readonly property var it: { root.regV; return root.items[model.key] || null; }
                                        readonly property bool sel: root.curKey === model.key
                                        readonly property string act: it ? it.activity : "idle"
                                        property bool confirm: false
                                        Layout.fillWidth: true; height: 56; radius: 9
                                        color: sel ? root.cSel : (rh.containsMouse ? root.cHover : "transparent")
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        Hover { id: rh; onClicked: root.select(model.key); onExited: row.confirm = false }
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 10
                                            Dot { act: row.act; dim: !row.it || !row.it.started || row.it.ended }
                                            ColumnLayout {
                                                Layout.fillWidth: true; spacing: 3
                                                T { Layout.fillWidth: true; font.pixelSize: 14; color: row.sel ? root.cText : root.cText2; font.weight: row.sel ? Font.Medium : Font.Normal
                                                    text: root.titleOf(row.it, model.title) }
                                                T { Layout.fillWidth: true; font.pixelSize: 12; color: row.act === "waiting" ? root.cText : root.cMuted
                                                    text: !row.it ? "" : row.act === "waiting" ? "Needs you" + (row.it.note ? " — " + row.it.note : "")
                                                        : [!row.it.started ? "Paused" : row.it.ended ? "Exited" : row.act === "working" ? "Working" : "",
                                                           root.tilde(row.it.cwd), row.it.modelName || root.shortModel(row.it.selModel)].filter(x => x).join("  ·  ") }
                                            }
                                            T { visible: index < 9 && !rh.containsMouse && !row.confirm; text: "⌥" + (index + 1); font.family: root.monoFont; font.pixelSize: 11; color: root.cFaint }
                                            Rectangle {   // close (asks once if Claude is working)
                                                visible: rh.containsMouse || row.confirm; width: row.confirm ? 46 : 22; height: 22; radius: 6
                                                color: xh.containsMouse || row.confirm ? root.cSel : "transparent"
                                                T { visible: row.confirm; anchors.centerIn: parent; text: "End"; font.pixelSize: 11; font.weight: Font.Medium }
                                                Ic { visible: !row.confirm; anchors.centerIn: parent; text: "close"; font.pixelSize: 14; color: xh.containsMouse ? root.cText : root.cMuted }
                                                MouseArea { id: xh; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { if (row.act === "working" && !row.confirm) row.confirm = true; else root.closeSession(model.key); } }
                                            }
                                        }
                                    }
                                }

                                Label { visible: root.othersU.length > 0; text: "Other windows"; Layout.leftMargin: 10; Layout.topMargin: 22; Layout.bottomMargin: 6 }
                                Repeater {
                                    model: root.othersU
                                    Rectangle {
                                        id: orow
                                        readonly property string act: modelData.status === "busy" || modelData.status === "shell" ? "working" : modelData.status === "waiting" ? "waiting" : "idle"
                                        Layout.fillWidth: true; height: 56; radius: 9
                                        color: oh.containsMouse ? root.cHover : "transparent"
                                        Hover { id: oh; onClicked: root.focusOther(modelData.pid) }
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 10
                                            Dot { act: orow.act }
                                            ColumnLayout {
                                                Layout.fillWidth: true; spacing: 3
                                                T { Layout.fillWidth: true; text: modelData.title; font.pixelSize: 14; color: oh.containsMouse ? root.cText : root.cText2 }
                                                T { Layout.fillWidth: true; font.pixelSize: 12; color: root.cMuted
                                                    text: [orow.act === "working" ? "Working" : "Idle", root.tilde(modelData.cwd), modelData.mtime ? root.ago(modelData.mtime) : ""].filter(x => x).join("  ·  ") }
                                            }
                                            Ic { visible: oh.containsMouse; text: "arrow_outward"; font.pixelSize: 16; color: root.cText2 }
                                        }
                                    }
                                }
                            }
                        }

                        // history: resume a past conversation in the panel
                        ColumnLayout {
                            visible: root.page === "history"; Layout.fillWidth: true; Layout.fillHeight: true; Layout.topMargin: 22; spacing: 2
                            Label { text: "Recent conversations"; Layout.leftMargin: 10; Layout.bottomMargin: 6 }
                            ListView {
                                Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 2
                                model: root.history
                                delegate: Rectangle {
                                    id: hrow
                                    readonly property var o: root.others.find(x => x.sid === modelData.id) || null
                                    width: ListView.view.width; height: 56; radius: 9; color: hh.containsMouse ? root.cHover : "transparent"
                                    ColumnLayout {
                                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 3
                                        T { text: modelData.title; Layout.fillWidth: true; font.pixelSize: 14; color: hh.containsMouse ? root.cText : root.cText2 }
                                        T { Layout.fillWidth: true; font.pixelSize: 12; color: root.cMuted
                                            text: [root.tilde(modelData.cwd), hrow.o ? "Open in a window" : root.ago(modelData.mtime)].join("  ·  ") }
                                    }
                                    Hover { id: hh; onClicked: root.openHistory(modelData) }
                                }
                            }
                        }
                    }

                }
                Rectangle { Layout.fillHeight: true; width: 1; color: root.cLine }

                // ===== middle: the selected session's terminal + diff tabs =====
                ColumnLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0
                    RowLayout {
                        Layout.fillWidth: true; Layout.preferredHeight: 56; Layout.maximumHeight: 56; Layout.fillHeight: false; Layout.leftMargin: 20; Layout.rightMargin: 14; spacing: 4
                        Repeater {
                            model: [""].concat(root.tabs)
                            Item {
                                readonly property bool on: root.current === modelData
                                Layout.preferredHeight: 56; Layout.preferredWidth: Math.min(tabT.implicitWidth + (modelData === "" ? 0 : 22), 420) + 20
                                Hover { onClicked: { root.current = modelData; if (modelData === "" && root.cur) root.cur.focusTerm(); } }
                                T { id: tabT; anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter; width: Math.min(implicitWidth, 400)
                                    font.pixelSize: modelData === "" ? 14 : 12; font.weight: parent.on ? Font.Medium : Font.Normal
                                    font.family: modelData === "" ? root.textFont : root.monoFont
                                    color: parent.on ? root.cText : root.cMuted
                                    text: modelData === "" ? root.titleOf(root.cur, "") : root.base(modelData) }
                                Ic { visible: modelData !== ""; anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter
                                     text: "close"; font.pixelSize: 13; color: root.cMuted
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.tabs = root.tabs.filter(p => p !== modelData); if (root.current === modelData) { root.current = ""; if (root.cur) root.cur.focusTerm(); } } } }
                                Rectangle { visible: parent.on && root.tabs.length > 0; anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right; anchors.leftMargin: 10; anchors.rightMargin: 10; height: 1; color: root.accent }
                            }
                        }
                        Item { Layout.fillWidth: true }
                        T { text: root.cur ? root.tilde(root.cur.cwd) : ""; color: root.cMuted; font.family: root.monoFont; font.pixelSize: 11; Layout.maximumWidth: 360 }
                        Item { width: 14 }
                        RowLayout {
                            spacing: 7
                            readonly property string act: root.cur ? root.cur.activity : "idle"
                            Dot { act: parent.act }
                            T { text: parent.act === "working" ? "Working" : parent.act === "waiting" ? "Needs you" : "Idle"; font.pixelSize: 12; color: parent.act === "idle" ? root.cMuted : root.cText }
                        }
                        Item { width: 10 }
                        Rectangle {
                            width: 28; height: 28; radius: 7; color: fdh.containsMouse ? root.cSel : "transparent"
                            Ic { anchors.centerIn: parent; text: "close_fullscreen"; font.pixelSize: 15; color: fdh.containsMouse ? root.cText : root.cText2 }
                            Hover { id: fdh; onClicked: root.close() }
                        }
                    }

                    Rectangle {   // the terminal: solid black
                        Layout.fillWidth: true; Layout.fillHeight: true; Layout.leftMargin: 8; Layout.rightMargin: 8; Layout.bottomMargin: 8
                        radius: 12; color: "black"; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.06)
                        Item {
                            anchors.fill: parent; anchors.margins: 6
                            // every panel session's terminal lives here; only the selected one is visible, the rest keep running
                            Repeater {
                                model: slots
                                Session { anchors.fill: parent; ui: root }
                            }
                            Column {
                                anchors.centerIn: parent; spacing: 14; visible: slots.count === 0
                                T { anchors.horizontalCenter: parent.horizontalCenter; text: "No sessions open"; color: root.cText2 }
                                Btn { anchors.horizontalCenter: parent.horizontalCenter; label: "New session"; icon: "add"; primary: true; onClicked: root.newSession(root.home, "") }
                            }

                            // diff of one file
                            Item {
                                id: diff
                                anchors.fill: parent; anchors.margins: 10
                                visible: root.current !== ""
                                readonly property var f: root.cur ? (root.cur.edits.find(x => x.path === root.current) || null) : null
                                ColumnLayout {
                                    anchors.fill: parent; spacing: 12
                                    RowLayout {
                                        Layout.fillWidth: true; Layout.leftMargin: 6; spacing: 12
                                        T { text: root.tilde(root.current); font.family: root.monoFont; font.pixelSize: 12; Layout.fillWidth: true }
                                        T { text: diff.f ? "+" + diff.f.add : ""; color: root.cAdd; font.family: root.monoFont; font.pixelSize: 12 }
                                        T { text: diff.f ? "−" + diff.f.rem : ""; color: root.cDel; font.family: root.monoFont; font.pixelSize: 12 }
                                        T { text: diff.f ? diff.f.n + (diff.f.n === 1 ? " edit" : " edits") : ""; color: root.cMuted; font.pixelSize: 12 }
                                        Btn { label: "Terminal"; icon: "arrow_back"; onClicked: { root.current = ""; if (root.cur) root.cur.focusTerm(); } }
                                    }
                                    Rule { Layout.fillWidth: true }
                                    ListView {
                                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; boundsBehavior: Flickable.StopAtBounds
                                        model: diff.f ? diff.f.rows : []
                                        delegate: Rectangle {
                                            width: ListView.view.width; height: modelData.k === "gap" ? 16 : 20
                                            color: modelData.k === "add" ? root.a(root.cAdd, 0.09) : modelData.k === "del" ? root.a(root.cDel, 0.09) : "transparent"
                                            Rectangle { visible: modelData.k === "sep"; anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 1; color: root.cLine }
                                            Row {
                                                visible: modelData.k !== "sep"; anchors.verticalCenter: parent.verticalCenter; spacing: 14
                                                Text { width: 44; horizontalAlignment: Text.AlignRight; text: modelData.k === "gap" ? "⋯" : modelData.n; color: root.cFaint; font.family: root.monoFont; font.pixelSize: 12 }
                                                Text { text: modelData.k === "add" ? "+" : modelData.k === "del" ? "−" : " "; color: modelData.k === "add" ? root.cAdd : root.cDel; font.family: root.monoFont; font.pixelSize: 12 }
                                                Text { text: modelData.t; textFormat: Text.PlainText; color: modelData.k === "ctx" ? root.cText2 : root.cText; font.family: root.monoFont; font.pixelSize: 12 }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Rectangle { Layout.fillHeight: true; width: 1; color: root.cLine }

                // ===== right: the selected session's model, effort, usage, tasks, files =====
                ColumnLayout {
                    id: rcol
                    Layout.preferredWidth: 300; Layout.maximumWidth: 300; Layout.fillHeight: true; spacing: 0
                    readonly property bool busy: !root.cur || root.cur.activity === "working"
                    readonly property string mname: root.cur ? (root.cur.modelName || root.shortModel(root.cur.selModel)) : ""
                    Item { implicitHeight: 20 }

                    ColumnLayout {
                        Layout.fillWidth: true; Layout.leftMargin: 18; Layout.rightMargin: 18; spacing: 8
                        RowLayout { Label { text: "Model"; Layout.fillWidth: true } T { text: rcol.mname || "—"; color: root.cText2; font.pixelSize: 12 } }
                        GridLayout {
                            columns: 2; Layout.fillWidth: true; columnSpacing: 4; rowSpacing: 4
                            Repeater {
                                model: [["Opus 5.5", "claude-opus-5-5"], ["Sonnet 5.5", "claude-sonnet-5-5"], ["Fable 5.2", "claude-fable-5-2"], ["Haiku 5.5", "claude-haiku-5-5"]]
                                Opt { Layout.fillWidth: true; label: modelData[0]; on: rcol.mname.toLowerCase().indexOf(modelData[0].split(" ")[0].toLowerCase()) >= 0
                                      opacity: rcol.busy && !on ? 0.45 : 1; enabled: !rcol.busy
                                      onClicked: { root.cur.selModel = modelData[1]; root.cur.relaunch(); } }
                            }
                        }
                        Label { text: "Effort"; Layout.topMargin: 10 }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 4
                            Repeater {
                                model: ["low", "medium", "high", "xhigh", "max"]
                                Opt { Layout.fillWidth: true; label: modelData === "medium" ? "Med" : modelData === "xhigh" ? "XHigh" : modelData.charAt(0).toUpperCase() + modelData.slice(1)
                                      on: !!root.cur && root.cur.effort === modelData
                                      opacity: rcol.busy && !on ? 0.45 : 1; enabled: !rcol.busy
                                      onClicked: { root.cur.selEffort = modelData; root.cur.relaunch(); } }
                            }
                        }
                    }
                    Rule { Layout.fillWidth: true; Layout.topMargin: 22 }

                    ColumnLayout {
                        id: ucol
                        Layout.fillWidth: true; Layout.leftMargin: 18; Layout.rightMargin: 18; Layout.topMargin: 18; spacing: 8
                        readonly property real pct: root.cur ? root.cur.ctxPct : -1
                        Label { text: "Usage" }
                        T { visible: !root.lim("five_hour") && !root.lim("seven_day"); text: "Shows after the first answer"; color: root.cMuted; font.pixelSize: 12 }
                        Repeater {
                            model: [["five_hour", "Session"], ["seven_day", "Week"]]
                            ColumnLayout {
                                readonly property var l: root.lim(modelData[0])
                                visible: !!l; Layout.fillWidth: true; spacing: 6; Layout.bottomMargin: 4
                                RowLayout { T { text: modelData[1]; font.pixelSize: 12; color: root.cText2 }
                                    T { Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; text: l ? root.fmtReset(l.resets_at) : ""; color: root.cMuted; font.pixelSize: 11 }
                                    T { Layout.preferredWidth: 38; horizontalAlignment: Text.AlignRight; text: l ? Math.round(l.used_percentage) + "%" : ""; font.family: root.monoFont; font.pixelSize: 12
                                        color: l && l.used_percentage >= 80 ? root.cHot : root.cText } }
                                Bar { Layout.fillWidth: true; v: l ? l.used_percentage / 100 : 0; c: l && l.used_percentage >= 80 ? root.cHot : root.accent }
                            }
                        }
                        RowLayout { Layout.topMargin: 6
                            T { text: "Context"; font.pixelSize: 12; color: root.cText2 }
                            T { Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; color: root.cMuted; font.pixelSize: 11
                                text: ucol.pct >= 0 && root.cur.ctx.context_window_size ? root.fmtTok(root.cur.ctx.context_window_size * ucol.pct / 100) + " of " + root.fmtTok(root.cur.ctx.context_window_size) : "" }
                            T { Layout.preferredWidth: 38; horizontalAlignment: Text.AlignRight; text: ucol.pct >= 0 ? Math.round(ucol.pct) + "%" : "—"; font.family: root.monoFont; font.pixelSize: 12
                                color: ucol.pct >= 80 ? root.cHot : root.cText } }
                        Bar { Layout.fillWidth: true; v: Math.max(0, ucol.pct) / 100; c: ucol.pct >= 80 ? root.cHot : root.accent }
                    }
                    Rule { Layout.fillWidth: true; Layout.topMargin: 22 }

                    ColumnLayout {
                        id: tcol
                        Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredHeight: 3; Layout.leftMargin: 18; Layout.rightMargin: 12; Layout.topMargin: 18; spacing: 8
                        readonly property var tk: root.cur ? root.cur.tasks : []
                        RowLayout {
                            Label { text: "Tasks"; Layout.fillWidth: true }
                            T { visible: tcol.tk.length > 0; text: tcol.tk.filter(x => x.s === "completed").length + "/" + tcol.tk.length; color: root.cMuted; font.pixelSize: 11; font.family: root.monoFont; Layout.rightMargin: 6 }
                        }
                        T { visible: !!root.cur && root.cur.note !== ""; text: root.cur ? root.cur.note : ""; color: root.cText; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true; maximumLineCount: 3 }
                        T { visible: tcol.tk.length === 0; text: "No tasks yet"; color: root.cFaint; font.pixelSize: 12 }
                        ListView {
                            Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 2
                            model: tcol.tk
                            delegate: RowLayout {
                                readonly property string st: modelData.s
                                width: ListView.view.width; spacing: 10
                                Rectangle {   // done = filled, in progress = white ring, pending = faint ring
                                    Layout.alignment: Qt.AlignTop; Layout.topMargin: 5; width: 8; height: 8; radius: 4
                                    color: parent.st === "completed" ? root.cMuted : "transparent"
                                    border.width: parent.st === "completed" ? 0 : 1.5; border.color: parent.st === "in_progress" ? root.accent : root.cFaint
                                }
                                T { Layout.fillWidth: true; Layout.bottomMargin: 6; text: modelData.t; wrapMode: Text.Wrap; maximumLineCount: 2; font.pixelSize: 12
                                    color: parent.st === "completed" ? root.cMuted : parent.st === "in_progress" ? root.cText : root.cText2 }
                            }
                        }
                    }
                    Rule { Layout.fillWidth: true }

                    ColumnLayout {
                        id: fcol
                        Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredHeight: 2; Layout.leftMargin: 18; Layout.rightMargin: 12; Layout.topMargin: 18; Layout.bottomMargin: 10; spacing: 6
                        readonly property var ed: root.cur ? root.cur.edits : []
                        RowLayout {
                            Label { text: "Changed files"; Layout.fillWidth: true }
                            T { visible: fcol.ed.length > 0; text: fcol.ed.length; color: root.cMuted; font.pixelSize: 11; font.family: root.monoFont; Layout.rightMargin: 6 }
                        }
                        T { visible: fcol.ed.length === 0; text: "Nothing changed yet"; color: root.cFaint; font.pixelSize: 12 }
                        ListView {
                            Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 0
                            model: fcol.ed
                            delegate: Rectangle {
                                width: ListView.view.width; height: 40; radius: 7
                                color: root.current === modelData.path ? root.cSel : (eh.containsMouse ? root.cHover : "transparent")
                                ColumnLayout {
                                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 1
                                    RowLayout {
                                        spacing: 8
                                        T { text: root.base(modelData.path); font.family: root.monoFont; font.pixelSize: 12; Layout.fillWidth: true }
                                        T { text: "+" + modelData.add; color: root.cAdd; font.family: root.monoFont; font.pixelSize: 11 }
                                        T { text: "−" + modelData.rem; color: root.cDel; font.family: root.monoFont; font.pixelSize: 11 }
                                    }
                                    T { text: root.shortDir(modelData.path); color: root.cMuted; font.family: root.monoFont; font.pixelSize: 10; Layout.fillWidth: true }
                                }
                                Hover { id: eh; onClicked: { if (root.tabs.indexOf(modelData.path) < 0) root.tabs = root.tabs.concat([modelData.path]); root.current = modelData.path; } }
                            }
                        }
                    }
                }
            }

            // boot screen: the first time the panel opens after it starts. Black, a greeting, a hairline that draws out.
            Rectangle {
                id: boot
                anchors.fill: parent
                color: "black"; opacity: 0; visible: opacity > 0.01
                MouseArea { anchors.fill: parent; enabled: boot.visible; onClicked: bootAnim.complete() }
                function play() { opacity = 1; hi.opacity = 0; hi.anchors.verticalCenterOffset = 10; line.width = 0; sub.opacity = 0; bootAnim.restart(); }
                SequentialAnimation {
                    id: bootAnim
                    PauseAnimation { duration: 120 }
                    ParallelAnimation {
                        NumberAnimation { target: hi; property: "opacity"; to: 1; duration: 700; easing.type: Easing.OutCubic }
                        NumberAnimation { target: hi; property: "anchors.verticalCenterOffset"; to: 0; duration: 800; easing.type: Easing.OutCubic }
                        NumberAnimation { target: line; property: "width"; to: 220; duration: 1100; easing.type: Easing.InOutCubic }
                    }
                    NumberAnimation { target: sub; property: "opacity"; to: 1; duration: 400 }
                    PauseAnimation { duration: 600 }
                    NumberAnimation { target: boot; property: "opacity"; to: 0; duration: 450; easing.type: Easing.InOutCubic }
                }
                Text {
                    id: hi
                    anchors.centerIn: parent
                    text: "hi " + root.greetName; color: "white"; renderType: Text.NativeRendering
                    font.family: root.textFont; font.pixelSize: 44; font.weight: Font.Light; font.letterSpacing: -0.5
                }
                Rectangle { id: line; anchors.horizontalCenter: parent.horizontalCenter; anchors.top: hi.bottom; anchors.topMargin: 22; height: 1; color: Qt.rgba(1, 1, 1, 0.35) }
                Text {
                    id: sub
                    anchors.horizontalCenter: parent.horizontalCenter; anchors.top: line.bottom; anchors.topMargin: 16
                    text: "CLAUDE"; color: root.cMuted; font.family: root.textFont; font.pixelSize: 11; font.weight: Font.Medium; font.letterSpacing: 5
                }
            }
        }
    }
}
