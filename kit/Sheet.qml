import QtQuick
import QtQuick.Effects
import qs.services

// A question or a form over the window: the window steps back under a scrim, a card in the middle holds a title, its
// body and its actions. Esc or a click outside dismisses it.
FocusScope {
    id: root
    anchors.fill: parent
    z: 800
    property string title: ""
    property string subtitle: ""
    property real cardWidth: Theme.dp(440)
    property bool dismissable: true
    default property alias body: bodyCol.data
    property alias actions: actionsRow.data
    property bool closing: false
    signal dismissed()

    function close(): void {
        if (root.closing) return
        root.closing = true
        root.dismissed()
        fadeOut.start()
    }
    Component.onCompleted: root.forceActiveFocus()
    Keys.onEscapePressed: if (root.dismissable) root.close()

    opacity: 0
    NumberAnimation on opacity { to: 1; duration: Theme.normal; easing.type: Easing.OutCubic }
    NumberAnimation { id: fadeOut; target: root; property: "opacity"; to: 0; duration: Theme.fast; onFinished: root.destroy() }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: if (root.dismissable) root.close()
            onWheel: wheel => wheel.accepted = true
        }
    }
    RectangularShadow {
        anchors.fill: card
        radius: card.radius
        blur: Theme.dp(40)
        offset.y: Theme.dp(12)
        color: Theme.shadow
    }
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(root.cardWidth, root.width - Theme.dp(40))
        height: Math.min(content.implicitHeight + Theme.dp(44), root.height - Theme.dp(40))
        radius: Theme.corner
        color: Theme.light ? "#ffffff" : Theme.mix(Theme.surface, Theme.high, 0.9)
        scale: 0.96 + 0.04 * root.opacity
        clip: true
        Rectangle { x: parent.radius; width: parent.width - parent.radius * 2; y: 1; height: 1; color: Theme.edge }
        MouseArea { anchors.fill: parent }
        Column {
            id: content
            x: Theme.dp(22)
            y: Theme.dp(22)
            width: parent.width - Theme.dp(44)
            spacing: Theme.dp(14)
            Column {
                width: parent.width
                spacing: Theme.dp(4)
                visible: root.title.length > 0
                Txt {
                    width: parent.width
                    text: root.title
                    font.family: Theme.title
                    size: Theme.head * 1.12
                    strong: true
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                }
                Txt {
                    width: parent.width
                    visible: root.subtitle.length > 0
                    text: root.subtitle
                    color: Theme.ink2
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                }
            }
            Column {
                id: bodyCol
                width: parent.width
                spacing: Theme.dp(10)
            }
            Row {
                id: actionsRow
                anchors.right: parent.right
                spacing: Theme.dp(8)
                layoutDirection: Qt.LeftToRight
            }
        }
    }
}
