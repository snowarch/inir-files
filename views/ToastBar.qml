import QtQuick
import QtQuick.Effects
import qs.services
import qs.kit

// A short word at the foot of the window after a change, with a way to take it back. It leaves on its own.
Item {
    id: root
    readonly property bool shown: Toast.text.length > 0
    width: Math.min(parent.width - Theme.dp(40), Math.max(Theme.dp(260), row.implicitWidth + Theme.dp(28)))
    height: Theme.dp(46)
    opacity: root.shown ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }
    transform: Translate { y: root.shown ? 0 : Theme.dp(12); Behavior on y { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } } }

    Timer {
        id: life
        interval: Toast.error ? 7000 : 5000
        running: root.shown && !mouse.containsMouse
        onTriggered: Toast.dismiss()
    }
    Connections {
        target: Toast
        function onSerialChanged() { life.restart() }
    }

    RectangularShadow {
        anchors.fill: face
        radius: face.radius
        blur: Theme.dp(24)
        offset.y: Theme.dp(6)
        color: Theme.shadow
    }
    Rectangle {
        id: face
        anchors.fill: parent
        radius: height / 2
        color: Theme.light ? "#1d1e22" : Theme.mix(Theme.highest, Theme.ink, 0.1)
        Rectangle { x: parent.radius; width: parent.width - parent.radius * 2; height: 1; color: Qt.rgba(1, 1, 1, 0.08) }
        MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true }
        Row {
            id: row
            anchors.centerIn: parent
            spacing: Theme.dp(10)
            Glyph {
                anchors.verticalCenter: parent.verticalCenter
                name: Toast.error ? "error" : "check_circle"
                fill: 1
                size: Theme.dp(18)
                color: Toast.error ? "#ff6961" : Theme.light ? Theme.mix(Theme.accent, "#ffffff", 0.45) : Theme.accent
            }
            Txt {
                anchors.verticalCenter: parent.verticalCenter
                text: Toast.text
                color: "#f2f3f5"
                width: Math.min(implicitWidth, root.parent ? root.parent.width - Theme.dp(220) : implicitWidth)
            }
            Rectangle {
                visible: Toast.action.length > 0
                anchors.verticalCenter: parent.verticalCenter
                height: Theme.dp(30)
                width: actText.implicitWidth + Theme.dp(22)
                radius: height / 2
                color: actMouse.pressed ? Qt.rgba(1, 1, 1, 0.22) : actMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.1)
                Txt { id: actText; anchors.centerIn: parent; text: Toast.action; strong: true; color: "#ffffff" }
                MouseArea { id: actMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Toast.act() }
            }
            Act {
                anchors.verticalCenter: parent.verticalCenter
                size: Theme.dp(26)
                glyphSize: Theme.dp(15)
                glyph: "close"
                tint: "#c8c9ce"
                round: true
                onClicked: Toast.dismiss()
            }
        }
    }
}
