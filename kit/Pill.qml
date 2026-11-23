import QtQuick
import qs.services

// A text button. "solid" is the accent's pill, the one thing a view asks for; "quiet" a fill; "danger" red for what
// cannot come back; "plain" text alone.
Item {
    id: root
    property string text: ""
    property string glyph: ""
    property string kind: "quiet"
    property bool compact: false
    readonly property bool hovered: mouse.containsMouse
    signal clicked()

    implicitHeight: root.compact ? Theme.dp(28) : Theme.dp(34)
    implicitWidth: row.implicitWidth + (root.compact ? Theme.dp(22) : Theme.dp(30))
    opacity: root.enabled ? 1 : 0.4
    activeFocusOnTab: root.enabled && root.visible
    Keys.onReturnPressed: root.clicked()
    Keys.onEnterPressed: root.clicked()
    Keys.onSpacePressed: root.clicked()

    Rectangle {
        visible: root.activeFocus
        anchors.fill: parent
        anchors.margins: -Theme.dp(3)
        radius: height / 2
        color: "transparent"
        border.width: Math.max(1, Theme.dp(2))
        border.color: Theme.accent
    }

    readonly property color base: root.kind === "solid" ? Theme.accent : root.kind === "danger" ? Theme.danger : root.kind === "quiet" ? Theme.fill : "transparent"
    readonly property color ink: root.kind === "solid" ? Theme.inkAccent : root.kind === "danger" ? "#ffffff" : Theme.ink

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.base
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: root.kind === "solid" || root.kind === "danger" ? (Theme.light ? "#000000" : "#ffffff") : Theme.ink
            opacity: mouse.pressed ? 0.14 : root.hovered ? 0.07 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.fast } }
        }
        // The edge of light along the top of a solid pill.
        Rectangle {
            visible: root.kind === "solid" || root.kind === "danger"
            x: parent.radius * 0.6
            width: parent.width - parent.radius * 1.2
            height: 1
            color: Qt.rgba(1, 1, 1, Theme.light ? 0.3 : 0.22)
        }
    }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: Theme.dp(6)
        Glyph {
            visible: root.glyph.length > 0
            anchors.verticalCenter: parent.verticalCenter
            name: root.glyph
            size: Theme.dp(17)
            color: root.ink
        }
        Txt {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: root.ink
            strong: true
            size: root.compact ? Theme.small : Theme.body
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
