import QtQuick
import qs.services

// A place pressed into the surface: darker along its top edge, lit along its bottom one.
Rectangle {
    id: root
    property bool focused: false
    radius: Theme.radius
    color: Theme.inset
    Rectangle {
        x: root.radius * 0.7
        width: parent.width - root.radius * 1.4
        height: 1
        color: Theme.insetShadow
    }
    Rectangle {
        x: root.radius * 0.7
        width: parent.width - root.radius * 1.4
        y: parent.height - 1
        height: 1
        color: Theme.insetLight
    }
    // Focus: a quiet ring in the accent, no outline otherwise.
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: Math.max(1, Theme.dp(2))
        border.color: Theme.alpha(Theme.accent, 0.7)
        opacity: root.focused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
    }
}
