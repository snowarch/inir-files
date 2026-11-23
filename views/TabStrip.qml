import QtQuick
import qs.services
import qs.kit

// The open tabs, shown once there is more than one. A tab can be dragged along the strip, closed with its cross or a
// middle click, and takes a drag to open itself.
Item {
    id: root
    required property var browser
    implicitHeight: Theme.dp(40)
    readonly property real tabWidth: Math.max(Theme.dp(120), Math.min(Theme.dp(230), (root.width - Theme.dp(60)) / Math.max(1, root.browser.tabs.length)))

    Row {
        id: strip
        x: Theme.dp(10)
        anchors.bottom: parent.bottom
        height: Theme.dp(34)
        spacing: Theme.dp(4)
        Repeater {
            model: root.browser.tabs
            delegate: Item {
                id: tab
                required property var modelData
                required property int index
                readonly property bool current: root.browser.tabIndex === tab.index
                property bool dropping: false
                width: root.tabWidth
                height: strip.height
                z: tabMouse.drag.active ? 5 : 0
                Rectangle {
                    id: face
                    width: parent.width
                    height: parent.height
                    radius: Theme.dp(11)
                    color: tab.current ? (Theme.light ? "#ffffff" : Theme.mix(Theme.canvas, Theme.ink, 0.08)) : tab.dropping ? Theme.selection : tabMouse.containsMouse ? Theme.fill : "transparent"
                    Rectangle { visible: tab.current; x: parent.radius; width: parent.width - parent.radius * 2; height: 1; color: Theme.edge }
                    Glyph {
                        id: tabGlyph
                        x: Theme.dp(10)
                        anchors.verticalCenter: parent.verticalCenter
                        name: tab.modelData.glyph
                        size: Theme.dp(16)
                        fill: tab.current ? 1 : 0
                        color: tab.current ? Theme.accentInk : Theme.ink3
                    }
                    Txt {
                        anchors.left: tabGlyph.right
                        anchors.leftMargin: Theme.dp(7)
                        anchors.right: close.left
                        anchors.rightMargin: Theme.dp(2)
                        anchors.verticalCenter: parent.verticalCenter
                        text: tab.modelData.title
                        size: Theme.body
                        strong: tab.current
                        color: tab.current ? Theme.ink : Theme.ink2
                    }
                    Act {
                        id: close
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.dp(4)
                        anchors.verticalCenter: parent.verticalCenter
                        size: Theme.dp(24)
                        glyphSize: Theme.dp(14)
                        glyph: "close"
                        opacity: tab.current || tabMouse.containsMouse || close.hovered ? 1 : 0
                        onClicked: root.browser.closeTab(tab.index)
                    }
                }
                MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    anchors.rightMargin: Theme.dp(30)
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    drag.target: face
                    drag.axis: Drag.XAxis
                    drag.threshold: Theme.dp(10)
                    onPressed: mouse => { if (mouse.button === Qt.LeftButton) root.browser.tabIndex = tab.index }
                    onClicked: mouse => { if (mouse.button === Qt.MiddleButton) root.browser.closeTab(tab.index) }
                    onReleased: {
                        if (face.x !== 0) {
                            const to = Math.max(0, Math.min(root.browser.tabs.length - 1, tab.index + Math.round(face.x / (root.tabWidth + strip.spacing))))
                            face.x = 0
                            if (to !== tab.index) root.browser.moveTab(tab.index, to)
                        }
                    }
                }
                DropArea {
                    anchors.fill: parent
                    onEntered: drag => {
                        if (!drag.hasUrls || tab.current) { drag.accepted = false; return }
                        tab.dropping = true
                        spring.restart()
                    }
                    onExited: { tab.dropping = false; spring.stop() }
                    onDropped: drop => { tab.dropping = false; drop.accepted = false }
                }
                Timer { id: spring; interval: 600; onTriggered: { tab.dropping = false; root.browser.tabIndex = tab.index } }
            }
        }
        Act {
            anchors.verticalCenter: parent.verticalCenter
            glyph: "add"
            size: Theme.dp(30)
            tip: I18n.tr("New tab")
            keys: "Ctrl+T"
            onClicked: root.browser.newTab(root.browser.activePane.folder.place)
        }
    }
}
