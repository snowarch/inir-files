import QtQuick
import qs.services

// A switch: the track pressed in, the knob raised; on, the track takes the accent.
Item {
    id: root
    property bool checked: false
    signal toggled(bool value)
    implicitWidth: Theme.dp(40)
    implicitHeight: Theme.dp(24)

    Inset {
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? Theme.accent : Theme.inset
        Behavior on color { ColorAnimation { duration: Theme.fast } }
    }
    Rectangle {
        width: parent.height - Theme.dp(6)
        height: width
        radius: width / 2
        y: Theme.dp(3)
        x: root.checked ? parent.width - width - Theme.dp(3) : Theme.dp(3)
        color: root.checked ? Theme.inkAccent : (Theme.light ? "#ffffff" : Theme.mix(Theme.highest, Theme.ink, 0.35))
        Behavior on x { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }
    }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled(!root.checked)
    }
}
