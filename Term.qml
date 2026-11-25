// The real Claude Code terminal (qmltermwidget). Loaded through a Loader so a missing module only blanks this pane.
// Color scheme C1Black (schemes/, see claude-panel.sh COLORSCHEMES_DIR): black text background with opacity 0,
// so the panel's own see-through black shows behind the text.
import QtQuick
import QMLTermWidget 2.0

Item {
    id: t
    property var args: []
    property string workDir: ""
    property color accent: "#9a8fc4"
    property bool running: false
    signal ended()
    signal hotkey(int n)          // Alt+1..9: switch session

    function send(s) { if (running) session.sendText(s); }
    function focusTerm() { term.forceActiveFocus(); }
    // after the panel is folded and shown again the widget does not repaint by itself: nudge its size by one column
    // (forces a real resize, so Claude redraws the whole screen), then put it back
    function refresh() { term.anchors.rightMargin = 24; nudge.restart(); }
    Timer { id: nudge; interval: 60; onTriggered: { term.anchors.rightMargin = 14; term.update(); } }
    function key(k, mods) { term.simulateKeyPress(k, mods || 0, true, 0, ""); }   // a press only: the widget turns releases into input too

    // the widget paints white until told otherwise: set black explicitly (after the scheme loads, and again once drawn)
    function tint() { term.setBackgroundColor("#000000"); term.setForegroundColor("#dedede"); }
    Component.onCompleted: { session.startShellProgram(); running = true; Qt.callLater(tint); tintAgain.start(); }
    Timer { id: tintAgain; interval: 300; onTriggered: t.tint() }

    QMLTermWidget {
        id: term
        anchors.fill: parent
        anchors.leftMargin: 12; anchors.topMargin: 8; anchors.bottomMargin: 8; anchors.rightMargin: 14
        font.family: "JetBrainsMono Nerd Font Mono"
        font.pointSize: 10.5
        colorScheme: "DarkPastels"   // our muted black palette, in schemes/ under a stock name (the widget would not pick up a new name)
        onColorSchemeChanged: Qt.callLater(t.tint)
        enableBold: true
        blinkingCursor: true
        session: QMLTermSession {
            id: session
            initialWorkingDirectory: t.workDir
            shellProgram: Qt.resolvedUrl("launch.sh").toString().replace("file://", "")
            shellProgramArgs: t.args
            onFinished: { t.running = false; t.ended(); }
        }
        Keys.onPressed: function(ev) {
            if ((ev.modifiers & Qt.ControlModifier) && (ev.modifiers & Qt.ShiftModifier)) {
                if (ev.key === Qt.Key_C) { term.copyClipboard(); ev.accepted = true; }
                else if (ev.key === Qt.Key_V) { term.pasteClipboard(); ev.accepted = true; }
            } else if ((ev.modifiers & Qt.AltModifier) && ev.key >= Qt.Key_1 && ev.key <= Qt.Key_9) {
                t.hotkey(ev.key - Qt.Key_1); ev.accepted = true;
            }
        }
    }
    QMLTermScrollbar {
        terminal: term
        anchors.right: parent.right; anchors.rightMargin: 3
        width: 4
        Rectangle { anchors.fill: parent; radius: 2; color: "white"; opacity: 0.18 }
    }
}
