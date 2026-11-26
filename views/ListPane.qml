import QtQuick
import QtQuick.Controls.Basic as QQC
import qs.services
import qs.kit

// The entries as rows with columns. The name column takes the room the others leave; each other column keeps the width
// it was dragged to. A click on a heading sorts by it, a second click turns the order.
Item {
    id: root
    required property var pane
    readonly property alias view: list
    readonly property bool sideways: list.contentWidth > list.width + 1
    readonly property var folder: root.pane.folder
    readonly property int zoom: Math.max(0, Math.min(2, root.pane.listZoom))
    readonly property real rowHeight: Theme.dp([28, 34, 46][root.zoom])
    readonly property real iconSize: Theme.dp([16, 22, 32][root.zoom])

    readonly property var keys: {
        const f = root.folder
        if (f.mode === "trash") return ["name", "origin", "deleted", "size"]
        if (f.mode === "recent") return ["name", "where", "mtime", "size"]
        if (f.mode === "search") return f.content ? ["name", "snippet", "where", "mtime"] : ["name", "where", "mtime", "size"]
        return ["name", "mtime", "size", "kind"]
    }
    readonly property var titles: ({ name: I18n.tr("Name"), size: I18n.tr("Size"), mtime: I18n.tr("Modified"), kind: I18n.tr("Kind"),
        origin: I18n.tr("Original location"), deleted: I18n.tr("Deleted"), where: I18n.tr("Location"), snippet: I18n.tr("Match") })
    readonly property var sortable: ({ name: "name", size: "size", mtime: "mtime", kind: "kind" })
    readonly property var defaults: ({ size: 132, mtime: 176, kind: 190, origin: 240, deleted: 150, where: 260, snippet: 320 })
    property var widths: Prefs.recall("columns", ({}))
    function widthOf(key: string): real { return root.widths[key] ?? Theme.dp(root.defaults[key] ?? 140) }
    // A narrow pane lets go of the last columns first, as responsive tables do, before the name falls under its least
    // width: the keys come in order of worth, and one column always stays beside the name.
    readonly property var columns: {
        const rest = root.keys.slice(1).map(k => ({ key: k, width: root.widthOf(k) }))
        const least = Theme.dp(220)
        const room = () => list.width - rest.reduce((a, c) => a + c.width, 0) - Theme.dp(12)
        while (rest.length > 1 && room() < least) rest.pop()
        return [{ key: "name", width: Math.max(least, room()) }].concat(rest)
    }
    readonly property real contentWidth: root.columns.reduce((a, c) => a + c.width, 0) + Theme.dp(12)

    function reveal(i: int): void { if (i >= 0) list.positionViewAtIndex(i, ListView.Contain) }
    function step(from: int, key: int): int {
        const per = Math.max(1, Math.floor(list.height / root.rowHeight) - 1)
        switch (key) {
        case Qt.Key_Up: return from < 0 ? 0 : from - 1
        case Qt.Key_Down: return from + 1
        case Qt.Key_PageUp: return Math.max(0, from - per)
        case Qt.Key_PageDown: return Math.min(list.count - 1, from + per)
        }
        return -1
    }
    function indicesIn(x1: real, y1: real, x2: real, y2: real): var {
        const out = []
        for (let i = Math.max(0, Math.floor(y1 / root.rowHeight)); i <= Math.floor(y2 / root.rowHeight) && i < list.count; i++) out.push(i)
        return out
    }

    // ---- headings
    Item {
        id: head
        width: parent.width
        height: Theme.dp(32)
        clip: true
        Row {
            x: Theme.dp(6) - list.contentX
            height: parent.height
            Repeater {
                model: root.columns
                delegate: Item {
                    id: col
                    required property var modelData
                    required property int index
                    readonly property string sortKey: root.sortable[modelData.key] ?? ""
                    readonly property bool sorted: col.sortKey.length > 0 && root.folder.sortKey === col.sortKey
                    width: modelData.width
                    height: head.height
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: Theme.dp(3)
                        radius: Theme.round(7)
                        color: colMouse.pressed ? Theme.fillPress : colMouse.containsMouse && col.sortKey.length > 0 ? Theme.fill : "transparent"
                    }
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        x: col.modelData.key === "size" ? parent.width - width - Theme.dp(12) : (col.index === 0 ? Theme.dp(10) + root.iconSize + Theme.dp(10) : Theme.dp(10))
                        spacing: Theme.dp(4)
                        layoutDirection: col.modelData.key === "size" ? Qt.RightToLeft : Qt.LeftToRight
                        Caption {
                            text: root.titles[col.modelData.key] ?? col.modelData.key
                            color: col.sorted ? Theme.ink : Theme.ink3
                        }
                        Glyph {
                            visible: col.sorted
                            anchors.verticalCenter: parent.verticalCenter
                            name: root.folder.desc ? "arrow_downward" : "arrow_upward"
                            size: Theme.dp(13)
                            weight: 600
                            color: Theme.ink2
                        }
                    }
                    MouseArea {
                        id: colMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: col.sortKey.length > 0
                        onClicked: root.pane.browser.actions.sortBy(col.sortKey)
                    }
                    // The edge between two headings moves the one on its left.
                    MouseArea {
                        visible: col.index > 0
                        x: parent.width - Theme.dp(4)
                        width: Theme.dp(8)
                        height: parent.height
                        z: 2
                        cursorShape: Qt.SplitHCursor
                        property real startX: 0
                        property real startW: 0
                        onPressed: mouse => { startX = mapToItem(head, mouse.x, 0).x; startW = col.modelData.width }
                        onPositionChanged: mouse => {
                            if (!pressed) return
                            const w = Math.max(Theme.dp(64), startW + mapToItem(head, mouse.x, 0).x - startX)
                            const next = Object.assign({}, root.widths)
                            next[col.modelData.key] = Math.round(w)
                            root.widths = next
                        }
                        onReleased: Prefs.remember("columns", root.widths)
                        onDoubleClicked: {
                            const next = Object.assign({}, root.widths)
                            delete next[col.modelData.key]
                            root.widths = next
                            Prefs.remember("columns", next)
                        }
                    }
                    Rectangle {
                        visible: col.index > 0
                        x: 0
                        anchors.verticalCenter: parent.verticalCenter
                        width: 1
                        height: parent.height * 0.42
                        color: Theme.line
                    }
                }
            }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
    }

    Item {
        id: body
        anchors.top: head.bottom
        anchors.bottom: parent.bottom
        width: parent.width

        Band {
            anchors.fill: parent
            pane: root.pane
            view: list
            indicesIn: root.indicesIn
            rowAt: (x, y) => list.indexAt(x, y)
        }

        ListView {
            id: list
            anchors.fill: parent
            topMargin: Theme.dp(4)
            bottomMargin: Theme.dp(24)
            clip: true
            acceptedButtons: Qt.NoButton
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.AutoFlickDirection
            contentWidth: root.contentWidth
            cacheBuffer: Math.max(0, root.rowHeight * 12)
            reuseItems: true
            model: root.folder.model
            currentIndex: -1
            delegate: Line {
                pane: root.pane
                columns: root.columns
                iconSize: root.iconSize
                width: Math.max(list.width, root.contentWidth)
                height: root.rowHeight
            }
            QQC.ScrollBar.vertical: Scroller {}
            QQC.ScrollBar.horizontal: Scroller { orientation: Qt.Horizontal }
        }
    }
}
