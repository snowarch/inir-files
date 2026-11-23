import QtQuick
import QtQuick.Controls.Basic as QQC
import qs.services
import qs.kit

// The way down as columns side by side: each folder above the one on screen, the one on screen, and what the chosen
// folder holds. A click in any column makes that column the place and chooses what was clicked.
Item {
    id: root
    required property var pane
    readonly property var folder: root.pane.folder
    readonly property alias view: current
    readonly property bool sideways: true
    // The list's zoom steps size the columns too.
    readonly property int zoom: Math.max(0, Math.min(2, Number(Prefs.get("listZoom"))))
    readonly property real colWidth: Theme.dp([228, 252, 292][root.zoom])
    readonly property real rowHeight: Theme.dp([26, 30, 38][root.zoom])
    readonly property real iconSize: Theme.dp([16, 18, 24][root.zoom])

    function under(path: string, top: string): bool { return path === top || path.startsWith(top.endsWith("/") ? top : top + "/") }
    readonly property string base: root.folder.mode !== "folder" ? "" : (root.under(root.folder.path, Core.home) ? Core.home : "/")
    readonly property var trail: {
        const f = root.folder
        if (f.mode !== "folder" || f.path === root.base) return []
        const out = []
        let p = Fmt.parent(f.path)
        for (let guard = 0; guard < 64; guard++) {
            out.unshift(p)
            if (p === root.base || p === "/") break
            p = Fmt.parent(p)
        }
        return out
    }
    readonly property var single: { void root.folder.selRev; return root.folder.selCount === 1 ? root.folder.chosen()[0] ?? null : null }
    readonly property string peek: root.single && root.single.dir ? root.single.path : ""

    function reveal(i: int): void { if (i >= 0) current.positionViewAtIndex(i, ListView.Contain) }
    function step(from: int, key: int): int {
        const per = Math.max(1, Math.floor(current.height / root.rowHeight) - 1)
        switch (key) {
        case Qt.Key_Up: return from < 0 ? 0 : from - 1
        case Qt.Key_Down: return from + 1
        case Qt.Key_PageUp: return Math.max(0, from - per)
        case Qt.Key_PageDown: return Math.min(current.count - 1, from + per)
        }
        return -1
    }
    // Left climbs a column, right steps into the chosen folder.
    function lateral(key: int): bool {
        const f = root.folder
        if (key === Qt.Key_Left && root.trail.length > 0) { f.focusPath = f.path; f.go(Fmt.parent(f.path)); return true }
        if (key === Qt.Key_Right && root.peek.length > 0) { f.selectFirst = true; f.go(root.peek); return true }
        return false
    }
    function indicesIn(x1: real, y1: real, x2: real, y2: real): var {
        const out = []
        for (let i = Math.max(0, Math.floor(y1 / root.rowHeight)); i <= Math.floor(y2 / root.rowHeight) && i < current.count; i++) out.push(i)
        return out
    }
    // A click in a column that is not the place: that column becomes the place, with what was clicked chosen.
    function pick(dir: string, path: string): void {
        root.pane.forceActiveFocus()
        root.folder.focusPath = path
        root.folder.go(dir)
    }

    component Entry: Item {
        id: row
        required property var entry
        property bool on: false
        property bool strong: false
        property bool joinUp: false
        property bool joinDown: false
        property bool dropping: false
        signal pressed(var mouse, Item from)
        width: root.colWidth
        height: root.rowHeight
        Rectangle {
            readonly property real r: Theme.dp(8)
            anchors.fill: parent
            anchors.leftMargin: Theme.dp(5)
            anchors.rightMargin: Theme.dp(5)
            topLeftRadius: row.joinUp ? 0 : r
            topRightRadius: row.joinUp ? 0 : r
            bottomLeftRadius: row.joinDown ? 0 : r
            bottomRightRadius: row.joinDown ? 0 : r
            color: row.dropping ? Theme.selectionHover : row.on ? (row.strong ? (rowMouse.containsMouse ? Theme.selectionHover : Theme.selection) : Theme.fillPress) : rowMouse.containsMouse ? Theme.fill : "transparent"
            border.width: row.dropping ? Math.max(1, Theme.dp(1.5)) : 0
            border.color: Theme.accent
        }
        FileIcon {
            id: rowIcon
            x: Theme.dp(12)
            y: Math.round((parent.height - height) / 2)
            size: root.iconSize
            entry: row.entry
            allowThumb: true
        }
        Txt {
            anchors.left: rowIcon.right
            anchors.leftMargin: Theme.dp(9)
            anchors.right: chevron.left
            anchors.rightMargin: Theme.dp(4)
            anchors.verticalCenter: parent.verticalCenter
            text: row.entry.name
            size: Theme.row
            elide: Text.ElideMiddle
            color: Theme.ink
        }
        Glyph {
            id: chevron
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(12)
            anchors.verticalCenter: parent.verticalCenter
            visible: row.entry.dir
            name: "chevron_right"
            size: Theme.dp(16)
            color: row.on ? Theme.ink2 : Theme.ink3
        }
        MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            onPressed: mouse => row.pressed(mouse, rowMouse)
        }
        DropArea {
            anchors.fill: parent
            enabled: row.entry.dir
            onEntered: drag => {
                if (!drag.hasUrls || root.pane.browser.actions.dropRefused(drag.urls, row.entry.path)) { drag.accepted = false; return }
                row.dropping = true
            }
            onExited: row.dropping = false
            onDropped: drop => { row.dropping = false; root.pane.browser.actions.drop(drop, row.entry.path) }
        }
    }

    component Side: Rectangle {
        id: side
        required property string path
        property string next: ""
        width: root.colWidth
        height: strip.height
        color: "transparent"
        Listing { id: listing; path: side.path }
        ListView {
            anchors.fill: parent
            anchors.topMargin: Theme.dp(6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: listing.model
            delegate: Entry {
                required property var model
                entry: model
                on: model.path === side.next
                onPressed: (mouse, from) => {
                    if (mouse.button === Qt.MiddleButton) { if (model.dir) root.pane.browser.newTab(model.path); return }
                    root.pick(side.path, model.path)
                    if (mouse.button === Qt.RightButton) {
                        const p = from.mapToItem(root.pane.browser.stage, mouse.x, mouse.y)
                        Qt.callLater(() => root.pane.browser.actions.itemMenu(root.pane, p.x, p.y))
                    }
                }
            }
            QQC.ScrollBar.vertical: Scroller {}
        }
        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
    }

    Flickable {
        id: strip
        anchors.fill: parent
        clip: true
        contentWidth: lane.width
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        acceptedButtons: Qt.NoButton
        // The folder in view stays in view: as a column opens, and as the window or the aside changes its width.
        function toEnd(): void { strip.contentX = Math.max(0, strip.contentWidth - strip.width) }
        onContentWidthChanged: Qt.callLater(strip.toEnd)
        onWidthChanged: Qt.callLater(strip.toEnd)
        QQC.ScrollBar.horizontal: Scroller { orientation: Qt.Horizontal }

        Item {
            id: lane
            width: root.colWidth * (root.trail.length + 1 + (root.peek.length > 0 ? 1 : 0))
            height: strip.height

            Repeater {
                model: root.trail
                delegate: Side {
                    required property var modelData
                    required property int index
                    x: index * root.colWidth
                    path: modelData
                    next: root.trail[index + 1] ?? root.folder.path
                }
            }

            Item {
                id: here
                x: root.trail.length * root.colWidth
                width: root.colWidth
                height: lane.height
                Band {
                    anchors.fill: parent
                    pane: root.pane
                    view: current
                    indicesIn: root.indicesIn
                    rowAt: (x, y) => current.indexAt(x, y)
                }
                ListView {
                    id: current
                    anchors.fill: parent
                    anchors.topMargin: Theme.dp(6)
                    clip: true
                    acceptedButtons: Qt.NoButton
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.folder.model
                    currentIndex: -1
                    delegate: Entry {
                        id: hereRow
                        required property var model
                        required property int index
                        entry: model
                        on: { void root.folder.selRev; return root.folder.isSel(model.path) }
                        strong: root.pane.active
                        joinUp: { void root.folder.selRev; const e = root.folder.all[hereRow.index - 1]; return hereRow.on && !!e && root.folder.isSel(e.path) }
                        joinDown: { void root.folder.selRev; const e = root.folder.all[hereRow.index + 1]; return hereRow.on && !!e && root.folder.isSel(e.path) }
                        onPressed: (mouse, from) => {
                            root.pane.pressItem(hereRow.index, mouse, from)
                            if (mouse.button === Qt.LeftButton) root.pane.ready(null, root.iconSize)
                        }
                        Loader {
                            active: root.pane.browser.renaming === hereRow.model.path
                            anchors.verticalCenter: parent.verticalCenter
                            x: Theme.dp(34)
                            width: parent.width - Theme.dp(44)
                            sourceComponent: NameEdit {
                                name: hereRow.model.name
                                onDone: name => root.pane.browser.actions.renameTo(hereRow.model.path, name)
                                onCancelled: root.pane.browser.actions.renameCancelled(root.pane)
                            }
                        }
                        MouseArea {
                            id: hereMouse
                            anchors.fill: parent
                            enabled: root.pane.browser.renaming !== hereRow.model.path
                            acceptedButtons: Qt.LeftButton
                            drag.target: dragProxy
                            drag.threshold: Theme.dp(8)
                            drag.onActiveChanged: { if (drag.active) root.pane.carry(); else { dragProxy.x = 0; dragProxy.y = 0 } }
                            onPressed: mouse => hereRow.pressed(mouse, hereMouse)
                            onReleased: mouse => { if (!drag.active) root.pane.releaseItem(hereRow.index, mouse) }
                            onDoubleClicked: mouse => { if (!Prefs.get("singleClick")) root.pane.openItem(hereRow.index, false) }
                        }
                        Item { id: dragProxy }
                    }
                    QQC.ScrollBar.vertical: Scroller {}
                }
                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
            }

            Loader {
                active: root.peek.length > 0
                x: (root.trail.length + 1) * root.colWidth
                sourceComponent: Side { path: root.peek }
            }
        }
    }
}
