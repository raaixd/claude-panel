// One Claude Code session in the panel: its terminal, plus what its hooks report (edits, tasks, activity, status).
// Every session has its own folder ui.runDir/s/<key> (events.jsonl, status.json, trust.json, settings.json).
// The session starts when you first select it, so sessions restored after a restart cost nothing until opened.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
    id: s
    property var ui                      // the panel (shell.qml root)
    required property string key
    required property string cwd
    required property string sid         // Claude's session id (from SessionStart, or the one to resume)
    required property string title
    required property string mdl         // saved model / effort (from the panel's list)
    required property string eff
    property string selModel: mdl        // --model / --effort for this session only (your saved default never changes)
    property string selEffort: eff
    readonly property string runDir: ui.runDir + "/s/" + key
    readonly property bool selected: ui.curKey === key
    visible: selected && ui.current === ""

    property bool started: false
    property bool ended: false
    property var edits: []               // [{path, add, rem, created, rows, n, ts}] newest first
    property var tasks: []               // [{id, t, s}]
    property string activity: "idle"     // idle | working | waiting
    property string note: ""
    property string lastPrompt: ""
    property real changedAt: Date.now()
    property var status: ({})
    property bool talked: false          // has at least one message (so it can be resumed)
    property bool sessionLive: false     // SessionStart ran (= past the trust question)
    property bool needsTrust: false
    property bool trustSent: false
    property real termStartedAt: 0
    property real runStartedAt: 0        // when this run began (termStartedAt moves while answering trust)
    property real nowMs: 0
    property int seen: 0
    property bool replaying: true
    property var pendingArgs: []
    property bool ready: false           // the session folder exists (file watchers need the files to be there)
    readonly property var term: loader.item
    readonly property string modelName: (status.model && status.model.display_name) || ""
    readonly property string effort: (status.effort && status.effort.level) || selEffort
    readonly property var ctx: status.context_window || null
    readonly property real ctxPct: ctx && ctx.used_percentage != null ? ctx.used_percentage : -1

    property bool restored: false        // came from the saved list with a conversation to resume
    property int elsewhere: 0            // pid of another window that already has this conversation open
    property bool waitOthers: false
    Component.onCompleted: { restored = sid !== ""; ui.reg(key, s); if (selected) ensureStarted(); }
    Connections {   // resuming waits until the panel knows which conversations are open in other windows
        target: s.ui
        function onOthersLoadedChanged() { if (s.waitOthers) { s.waitOthers = false; s.ensureStarted(); } }
    }
    Component.onDestruction: ui.unreg(key)
    onSelectedChanged: if (selected) { if (!started) ensureStarted(); else if (term) refreshT.restart(); }
    onSidChanged: ui.save()
    onTitleChanged: ui.save()
    onActivityChanged: changedAt = Date.now()

    function ensureStarted() {
        if (started) return;
        if (sid && !ui.othersLoaded) { waitOthers = true; return; }
        // the same conversation running twice would write over itself: offer to go to it instead
        const o = sid ? ui.others.find(x => !x.panel && x.sid === sid) : null;
        if (o) { elsewhere = o.pid; return; }
        elsewhere = 0;
        let a = sid ? ["--resume", sid] : [];
        if (selModel) a = a.concat(["--model", selModel]);
        if (selEffort) a = a.concat(["--effort", selEffort]);
        start(a, false);
    }
    function start(extra, keep) {
        started = true; ended = false;
        sessionLive = false; trustSent = false; needsTrust = false; termStartedAt = Date.now(); runStartedAt = termStartedAt; nowMs = Date.now();
        if (!keep) { status = ({}); activity = "idle"; note = ""; edits = []; tasks = []; seen = 0; replaying = true; }
        // keep the panel's record (changed files, tasks) when the same conversation continues: a model/effort
        // switch, or resuming a saved session after a restart. Only a brand-new conversation starts empty.
        const same = keep || extra.indexOf("--resume") >= 0;
        pendingArgs = ["--run", runDir].concat(same ? ["--keep"] : []).concat(extra);
        loader.source = "";
        if (!keep) ready = false;
        prep.running = true;     // make the session folder first, so the file watchers have something to watch
    }
    // switch model/effort: relaunch the SAME conversation with the new flags
    function relaunch() {
        let a = (sid && talked) ? ["--resume", sid] : [];
        if (selModel) a = a.concat(["--model", selModel]);
        if (selEffort) a = a.concat(["--effort", selEffort]);
        activity = "idle"; ui.current = "";
        start(a, true); ui.save();
    }
    function restartFresh() { sid = ""; talked = false; restored = false; title = ""; elsewhere = 0; start([], false); ui.save(); }
    function focusTerm() { if (term) term.focusTerm(); }
    function refresh() { if (term) term.refresh(); }
    Timer { id: refreshT; interval: 120; onTriggered: { s.refresh(); s.focusTerm(); } }

    Process {
        id: prep
        // a new conversation empties the record; trust is re-checked on every start
        command: ["sh", "-c", 'mkdir -p "$1" && chmod 700 "$1" && touch "$1/events.jsonl" && echo "{}" > "$1/trust.json" && if [ "$2" = fresh ]; then : > "$1/events.jsonl"; echo "{}" > "$1/status.json"; fi',
                  "sh", s.runDir, s.pendingArgs.indexOf("--keep") >= 0 ? "keep" : "fresh"]
        onExited: { s.ready = true; evFile.reload(); trustFile.reload(); loader.setSource("Term.qml", { workDir: s.cwd, args: s.pendingArgs }); }
    }

    // ---------- events from the hooks ----------
    FileView {
        id: evFile
        path: s.ready ? s.runDir + "/events.jsonl" : ""
        watchChanges: true
        onFileChanged: reload()
        onLoaded: s.ingest(text())
        onLoadFailed: s.seen = 0
    }
    function ingest(txt) {
        const lines = txt.split("\n").filter(l => l.length);
        if (lines.length < seen) { seen = 0; edits = []; tasks = []; }   // a fresh start emptied the file
        let ed = edits.slice(), tk = tasks.slice();
        for (let i = seen; i < lines.length; i++) {
            let e; try { e = JSON.parse(lines[i]); } catch (x) { continue; }
            if (e.e === "edit") {
                const j = ed.findIndex(f => f.path === e.path);
                const old = j >= 0 ? ed.splice(j, 1)[0] : { path: e.path, add: 0, rem: 0, rows: [], n: 0, created: false };
                const rows = old.rows.length ? old.rows.concat([{ k: "sep", n: 0, t: "" }], e.rows) : e.rows;
                ed.unshift({ path: e.path, add: old.add + e.add, rem: old.rem + e.rem, created: old.created || e.created,
                             rows: rows.slice(-1200), n: old.n + 1, ts: e.ts });
            } else if (e.e === "todos") {
                tk = e.todos.map((x, k) => ({ id: "todo" + k, t: x.t, s: x.s }));
            } else if (e.e === "task") {
                const j = tk.findIndex(x => x.id === e.id && e.id !== "");
                if (j >= 0) tk[j] = { id: e.id, t: e.t || tk[j].t, s: e.s || tk[j].s };
                else if (e.t) tk.push({ id: e.id, t: e.t, s: e.s || "pending" });
            } else if (e.e === "SessionStart") {
                if ((e.ts || 0) >= runStartedAt - 1000) sessionLive = true;   // only this run's start counts

                if (e.sid && e.sid !== sid) { talked = e.src === "resume"; sid = e.sid; }
                else if (e.src === "resume") talked = true;
            } else if (e.e === "UserPromptSubmit") {
                activity = "working"; note = ""; talked = true;
                if (e.p) { lastPrompt = e.p; if (!title) title = e.p; }
            }
            else if (e.e === "Stop") { activity = "idle"; note = ""; if (!replaying) ui.notify(s, "done"); }
            else if (e.e === "StopFailure") { activity = "idle"; note = "Stopped with an error"; }
            else if (e.e === "Notification") {
                // "Claude is waiting for your input" only means it has been idle a while: not a question for you
                if (/waiting for your input/i.test(e.msg || "")) continue;
                activity = "waiting"; note = e.msg || ""; if (!replaying) ui.notify(s, "needs");
            }
        }
        if (replaying) { activity = "idle"; note = ""; }   // a replayed record says nothing about right now
        seen = lines.length; edits = ed; tasks = tk; replaying = false;
    }
    FileView {
        path: s.ready ? s.runDir + "/status.json" : ""
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { try { s.status = JSON.parse(text()); if (s.status.rate_limits) s.ui.limits = s.status.rate_limits; } catch (x) { } }
    }
    FileView {
        id: trustFile
        path: s.ready ? s.runDir + "/trust.json" : ""
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { try { s.needsTrust = !!JSON.parse(text()).needs; } catch (x) { s.needsTrust = false; } }
    }

    // Claude asks "trust this folder?" (always in your home folder) and its default answer is "No, exit".
    // The panel answers Yes, only when launch.sh found the folder untrusted, so keys never land in Claude's input box.
    function trust() { if (!term) return; term.send("\x1b[B"); termStartedAt = Date.now() + 4000; trustEnter.restart(); }
    Timer { id: trustEnter; interval: 400; onTriggered: { if (s.term) s.term.send("\r"); s.focusTerm(); } }
    Timer { interval: 500; repeat: true; running: !s.sessionLive && !!s.term && !s.ended; onTriggered: { s.nowMs = Date.now(); if (!s.needsTrust) trustFile.reload(); } }   // re-read: launch.sh can write it before the watch is up
    readonly property bool askTrust: !sessionLive && !!term && term.running && nowMs - termStartedAt > 1800
    onNowMsChanged: if (needsTrust && !trustSent && !sessionLive && term && term.running && nowMs - termStartedAt > 2200) { trustSent = true; trust(); }

    // ---------- what you see ----------
    Loader {
        id: loader
        anchors.fill: parent
        onLoaded: {
            item.ended.connect(() => { s.ended = true; s.activity = "idle"; });
            item.hotkey.connect(n => s.ui.hotkey(n));
            if (s.selected && s.ui.shown) Qt.callLater(s.focusTerm);
        }
    }
    Column {
        anchors.centerIn: parent; spacing: 10; visible: loader.status === Loader.Error
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "The terminal module is missing."; color: s.ui.cText2; font.family: s.ui.textFont; font.pixelSize: 13 }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "sudo pacman -S qmltermwidget"; color: s.ui.cText; font.family: s.ui.monoFont; font.pixelSize: 13 }
    }
    component Pill: Rectangle {
        property string label: ""
        property bool primary: false
        signal clicked()
        width: pl.implicitWidth + 24; height: 30; radius: 8
        color: primary ? (ph.containsMouse ? "white" : "#f2f2f2") : (ph.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.06))
        Text { id: pl; anchors.centerIn: parent; text: parent.label; color: parent.primary ? "black" : s.ui.cText; font.family: s.ui.textFont; font.pixelSize: 12; font.weight: Font.Medium }
        MouseArea { id: ph; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
    }
    Rectangle {   // fallback if the automatic answer did not take
        visible: s.askTrust && s.trustSent && s.nowMs - s.termStartedAt > 8000
        anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 20
        width: trRow.implicitWidth + 28; height: 46; radius: 12; color: "#111111"; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
        RowLayout { id: trRow; anchors.centerIn: parent; spacing: 14
            Text { text: "Claude is asking to trust this folder"; color: s.ui.cText2; font.family: s.ui.textFont; font.pixelSize: 13 }
            Pill { label: "Trust"; primary: true; onClicked: s.trust() }
        }
    }
    Rectangle {
        visible: s.ended
        anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 20
        width: endRow.implicitWidth + 28; height: 46; radius: 12; color: "#111111"; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
        RowLayout { id: endRow; anchors.centerIn: parent; spacing: 8
            Text { text: "Claude exited"; color: s.ui.cText2; font.family: s.ui.textFont; font.pixelSize: 13; Layout.rightMargin: 6 }
            Pill { visible: !!s.sid && s.talked; label: "Resume"; primary: true; onClicked: s.start(["--resume", s.sid], true) }
            Pill { label: "New"; primary: !(s.sid && s.talked); onClicked: s.restartFresh() }
            Pill { label: "Close"; onClicked: s.ui.closeSession(s.key) }
        }
    }

    // this conversation is open in another window
    Column {
        visible: s.elsewhere !== 0 && !s.started
        anchors.centerIn: parent; spacing: 16
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "This conversation is open in another window"
               color: s.ui.cText; font.family: s.ui.textFont; font.pixelSize: 16; font.weight: Font.Light }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Running it here too would make the two copies write over each other."
               color: s.ui.cMuted; font.family: s.ui.textFont; font.pixelSize: 12 }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter; spacing: 8
            Pill { label: "Go to that window"; primary: true; onClicked: s.ui.focusOther(s.elsewhere) }
            Pill { label: "New session here"; onClicked: s.restartFresh() }
            Pill { label: "Check again"; onClicked: { s.elsewhere = 0; s.ui.othersLoaded = false; s.waitOthers = true; s.ui.refreshOthers(); } }
        }
    }

    // startup screen: covers the terminal while Claude starts (trust question included), then fades.
    // One sliding hairline, running only while it is on screen.
    Rectangle {
        id: splash
        anchors.fill: parent
        color: "black"
        readonly property bool want: s.started && !s.sessionLive && !s.ended && s.nowMs - s.termStartedAt < 9000
        opacity: want ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
        MouseArea { anchors.fill: parent; enabled: splash.want }
        Column {
            anchors.centerIn: parent; spacing: 14
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: s.sid ? "Resuming" : "Starting Claude"
                   color: s.ui.cText; font.family: s.ui.textFont; font.pixelSize: 17; font.weight: Font.Light }
            Item {
                width: 160; height: 1; anchors.horizontalCenter: parent.horizontalCenter; clip: true
                Rectangle { anchors.fill: parent; color: Qt.rgba(1, 1, 1, 0.08) }
                Rectangle {
                    width: 48; height: 1; color: Qt.rgba(1, 1, 1, 0.7)
                    NumberAnimation on x { running: splash.visible && s.ui.shown && s.selected; loops: Animation.Infinite; from: -48; to: 160; duration: 1100; easing.type: Easing.InOutSine }
                }
            }
            Text { anchors.horizontalCenter: parent.horizontalCenter; color: s.ui.cMuted; font.family: s.ui.monoFont; font.pixelSize: 11
                   text: s.ui.tilde(s.cwd) }
        }
    }
}
