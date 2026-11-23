import QtQuick
import Quickshell
import qs.services

// A glyph button: quiet until pointed at; on, it sits on the accent's plate.
Item {
    id: root
    property string glyph: ""
    property string tip: ""
    property string keys: ""
    property bool on: false
    property real size: Theme.dp(32)
    property real glyphSize: Theme.dp(19)
    property color tint: root.on ? Theme.accentInk : Theme.ink2
    property bool round: false
    readonly property bool hovered: mouse.containsMouse
    signal clicked(var mouse)
    signal pressAndHold()

    implicitWidth: root.size
    implicitHeight: root.size
    opacity: root.enabled ? 1 : 0.38
    activeFocusOnTab: false

    Hover {
        anchors.fill: parent
        radius: root.round ? width / 2 : Theme.radius
        hovered: root.hovered
        pressed: mouse.pressed
        on: root.on
    }
    Glyph {
        anchors.centerIn: parent
        name: root.glyph
        size: root.glyphSize
        color: root.hovered && !root.on ? Theme.ink : root.tint
        fill: root.on ? 1 : 0
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor
        onPressed: { root.spent = true; root.QsWindow.window?.tips?.hide(root) }
        onClicked: m => root.clicked(m)
        onPressAndHold: root.pressAndHold()
    }
    // The tip after a still moment over the button; once pressed, not again until the pointer comes back, so it never
    // lies over the menu or sheet the press opened.
    property bool spent: false
    Timer {
        interval: root.QsWindow.window?.tips?.delay ?? 650
        running: root.hovered && root.tip.length > 0 && !root.spent
        onTriggered: root.QsWindow.window?.tips?.show(root, root.tip, root.keys)
    }
    onHoveredChanged: if (!root.hovered) { root.spent = false; root.QsWindow.window?.tips?.hide(root) }
}
