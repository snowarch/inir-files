import QtQuick
import qs.services
import qs.kit

// The open tabs, shown once there is more than one. Reorder along the strip, pull vertically to detach into a new
// tiled window (for Niri/Umbriel), scroll the wheel to step across tabs, right-click for tab actions.
Item {
    id: root
    required property var browser
    implicitHeight: Theme.dp(40)
    readonly property real avail: Math.max(Theme.dp(120), root.width - Theme.dp(56))
    readonly property real tabWidth: Math.max(Theme.dp(126), Math.min(Theme.dp(220), (root.avail - Theme.dp(4) * Math.max(0, root.browser.tabs.length - 1)) / Math.max(1, root.browser.tabs.length)))

    function ensureCurrentVisible(): void {
        const x0 = root.browser.tabIndex * (root.tabWidth + strip.spacing)
        const x1 = x0 + root.tabWidth
        if (x0 < flick.contentX) flick.contentX = x0
        else if (x1 > flick.contentX + flick.width) flick.contentX = Math.max(0, x1 - flick.width)
    }
    Connections {
        target: root.browser
        function onTabIndexChanged() { Qt.callLater(root.ensureCurrentVisible) }
    }

    function menuFor(index: int): var {
        const b = root.browser
        const n = b.tabs.length
        const isCurrent = index === b.tabIndex
        return [
            { text: I18n.tr("New tab"), glyph: "add", keys: "Ctrl+T", run: () => b.newTab(b.tabs[index]?.activePane.folder.place ?? "", [], index + 1) },
            { text: I18n.tr("Duplicate tab"), glyph: "tab_duplicate", keys: "Ctrl+Shift+D", run: () => b.duplicateTab(index) },
            { text: I18n.tr("Move tab to new window"), glyph: "open_in_new", keys: "Ctrl+Alt+W", enabled: n > 1, run: () => b.detachTab(index) },
            !isCurrent && n > 1 ? { text: I18n.tr("Open in split view"), glyph: "vertical_split", run: () => b.splitWithTab(index) } : null,
            { separator: true },
            { text: I18n.tr("Move left"), glyph: "arrow_back", enabled: index > 0, run: () => b.moveTab(index, index - 1) },
            { text: I18n.tr("Move right"), glyph: "arrow_forward", enabled: index < n - 1, run: () => b.moveTab(index, index + 1) },
            { separator: true },
            { text: I18n.tr("Close other tabs"), glyph: "tab_close_inactive", enabled: n > 1, run: () => b.closeOtherTabs(index) },
            { text: I18n.tr("Close tabs to the right"), glyph: "tab_close_right", enabled: index < n - 1, run: () => b.closeTabsRight(index) },
            { text: I18n.tr("Reopen closed tab"), glyph: "restore_page", keys: "Ctrl+Shift+T", enabled: b.closedTabs.length > 0, run: () => b.reopenTab() },
            { text: I18n.tr("Close tab"), glyph: "close", keys: "Ctrl+W", run: () => b.closeTab(index) }
        ]
    }

    // Wheel over the strip steps between tabs; double-click empty space opens a new tab.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onDoubleClicked: root.browser.newTab(root.browser.activePane ? root.browser.activePane.folder.place : "")
        onWheel: wheel => {
            const d = wheel.angleDelta.y || wheel.angleDelta.x
            if (d !== 0) root.browser.stepTab(d > 0 ? -1 : 1)
        }
    }

    Flickable {
        id: flick
        anchors.left: parent.left
        anchors.leftMargin: Theme.dp(10)
        anchors.right: addBtn.left
        anchors.rightMargin: Theme.dp(6)
        anchors.bottom: parent.bottom
        height: Theme.dp(34)
        contentWidth: strip.implicitWidth
        contentHeight: height
        clip: true
        interactive: contentWidth > width
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds

        Row {
            id: strip
            height: flick.height
            spacing: Theme.dp(4)
            Repeater {
                model: root.browser.tabs
                delegate: Item {
                    id: tab
                    required property var modelData
                    required property int index
                    readonly property bool current: root.browser.tabIndex === tab.index
                    readonly property bool detaching: tabMouse.drag.active && root.browser.tabs.length > 1 && Math.abs(face.y) > Theme.dp(36)
                    property bool dropping: false
                    width: root.tabWidth
                    height: strip.height
                    z: tabMouse.drag.active ? 5 : 0
                    Rectangle {
                        id: face
                        width: parent.width
                        height: parent.height
                        radius: Theme.round(11)
                        color: tab.current ? (Theme.light ? "#ffffff" : Theme.mix(Theme.canvas, Theme.ink, 0.08)) : tab.dropping ? Theme.selection : tabMouse.containsMouse ? Theme.fill : "transparent"
                        border.width: tab.detaching ? Math.max(1, Theme.dp(1.5)) : 0
                        border.color: Theme.accent
                        opacity: tab.detaching ? 0.8 : 1
                        Behavior on color { ColorAnimation { duration: Theme.hoverMs } }
                        Rectangle { visible: tab.current && !tab.detaching; x: parent.radius; width: parent.width - parent.radius * 2; height: 1; color: Theme.edge }
                        Glyph {
                            id: tabGlyph
                            x: Theme.dp(10)
                            anchors.verticalCenter: parent.verticalCenter
                            name: tab.detaching ? "open_in_new" : tab.modelData.glyph
                            size: Theme.dp(16)
                            fill: tab.current ? 1 : 0
                            color: tab.current || tab.detaching ? Theme.accentInk : Theme.ink3
                        }
                        Txt {
                            anchors.left: tabGlyph.right
                            anchors.leftMargin: Theme.dp(7)
                            anchors.right: close.left
                            anchors.rightMargin: Theme.dp(2)
                            anchors.verticalCenter: parent.verticalCenter
                            text: tab.detaching ? I18n.tr("New window") : tab.modelData.title
                            size: Theme.body
                            strong: tab.current || tab.detaching
                            color: tab.current || tab.detaching ? Theme.ink : Theme.ink2
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
                        anchors.rightMargin: Theme.dp(28)
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                        drag.target: face
                        drag.axis: Drag.XAndYAxis
                        drag.threshold: Theme.dp(10)
                        onPressed: mouse => { if (mouse.button === Qt.LeftButton) root.browser.tabIndex = tab.index }
                        onClicked: mouse => {
                            if (mouse.button === Qt.MiddleButton) root.browser.closeTab(tab.index)
                            else if (mouse.button === Qt.RightButton) {
                                const at = tabMouse.mapToItem(root.browser.stage, mouse.x, mouse.y)
                                root.browser.menus.open(root.menuFor(tab.index), at.x, at.y)
                            }
                        }
                        onReleased: {
                            const dy = face.y
                            const dx = face.x
                            face.x = 0
                            face.y = 0
                            if (root.browser.tabs.length > 1 && Math.abs(dy) > Theme.dp(36)) {
                                root.browser.detachTab(tab.index)
                                return
                            }
                            if (dx !== 0) {
                                const to = Math.max(0, Math.min(root.browser.tabs.length - 1, tab.index + Math.round(dx / (root.tabWidth + strip.spacing))))
                                if (to !== tab.index) root.browser.moveTab(tab.index, to)
                            }
                        }
                        onWheel: wheel => {
                            const d = wheel.angleDelta.y || wheel.angleDelta.x
                            if (d !== 0) root.browser.stepTab(d > 0 ? -1 : 1)
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
        }
    }

    Act {
        id: addBtn
        anchors.right: parent.right
        anchors.rightMargin: Theme.dp(10)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.dp(2)
        glyph: "add"
        size: Theme.dp(30)
        tip: I18n.tr("New tab")
        keys: "Ctrl+T"
        onClicked: root.browser.newTab(root.browser.activePane ? root.browser.activePane.folder.place : "")
    }
}
