import QtQuick
import QtQuick.Controls.Basic as QQC
import qs.services
import qs.kit

// The entries as a wall of pictures with no names: each a square, cropped to fill, a thin gap apart. The zoom sets the
// least side of a square; the squares share the width evenly, so a row never ends in a ragged gap.
Item {
    id: root
    required property var pane
    readonly property alias view: grid
    readonly property var sizes: [64, 88, 112, 144, 184, 240, 320]
    readonly property int zoom: Math.max(1, Math.min(root.sizes.length, Number(Prefs.get("zoom"))))
    readonly property real least: Theme.dp(root.sizes[root.zoom - 1])
    readonly property real gap: Theme.dp(4)
    readonly property int columns: Math.max(1, Math.floor(grid.width / root.least))

    function reveal(i: int): void { if (i >= 0) grid.positionViewAtIndex(i, GridView.Contain) }
    // The next index for a key, or -1 when the key does not move in a grid.
    function step(from: int, key: int): int {
        const per = Math.max(1, Math.floor(grid.height / grid.cellHeight))
        switch (key) {
        case Qt.Key_Left: return from - 1
        case Qt.Key_Right: return from + 1
        case Qt.Key_Up: return from < 0 ? 0 : (from - root.columns >= 0 ? from - root.columns : from)
        case Qt.Key_Down: return from < 0 ? 0 : (from + root.columns < grid.count ? from + root.columns : Math.min(grid.count - 1, Math.floor(from / root.columns) < Math.floor((grid.count - 1) / root.columns) ? grid.count - 1 : from))
        case Qt.Key_PageUp: return Math.max(0, from - root.columns * per)
        case Qt.Key_PageDown: return Math.min(grid.count - 1, from + root.columns * per)
        }
        return -1
    }
    // What a band covers, in the grid's own coordinates: a tile counts when the band meets its square.
    function indicesIn(x1: real, y1: real, x2: real, y2: real): var {
        const out = []
        const c = grid.cellWidth
        if (c <= 0) return out
        const g = root.gap / 2
        for (let row = Math.max(0, Math.floor(y1 / c)); row <= Math.floor(y2 / c); row++) {
            for (let col = Math.max(0, Math.floor(x1 / c)); col <= Math.min(root.columns - 1, Math.floor(x2 / c)); col++) {
                const i = row * root.columns + col
                if (i >= grid.count) break
                const bx = col * c + g, by = row * c + g
                if (x2 >= bx && x1 <= bx + c - root.gap && y2 >= by && y1 <= by + c - root.gap) out.push(i)
            }
        }
        return out
    }

    // The folder's photos and films are made while the first screen is looked at, so a scroll finds them ready.
    function ahead(): void {
        const f = root.pane.folder
        if (f.mode !== "folder" || f.remote) return
        const px = (grid.cellWidth - root.gap) * (root.Window.window?.devicePixelRatio ?? 1)
        Core.thumbAhead(f.all.filter(e => !e.dir && (e.kind === "image" || e.kind === "video")), Core.thumbSize(px, true))
    }
    Timer { id: aheadSoon; interval: 250; onTriggered: root.ahead() }
    Connections { target: root.pane.folder; function onReset() { aheadSoon.restart() } }
    Component.onCompleted: aheadSoon.restart()
    onColumnsChanged: aheadSoon.restart()

    Band {
        anchors.fill: parent
        pane: root.pane
        view: grid
        indicesIn: root.indicesIn
    }

    GridView {
        id: grid
        anchors.fill: parent
        anchors.leftMargin: Theme.dp(8) - root.gap / 2
        anchors.rightMargin: Theme.dp(8) - root.gap / 2
        topMargin: Theme.dp(8) - root.gap / 2
        bottomMargin: Theme.dp(24)
        clip: true
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        cellWidth: Math.floor(grid.width / root.columns)
        cellHeight: grid.cellWidth
        cacheBuffer: Math.max(0, grid.cellHeight * 2)
        // Tiles scrolled out are handed to the entries scrolling in, not made again.
        reuseItems: true
        model: root.pane.folder.model
        currentIndex: -1
        delegate: Tile {
            pane: root.pane
            gap: root.gap
            width: grid.cellWidth
            height: grid.cellHeight
        }
        QQC.ScrollBar.vertical: Scroller {}
    }
}
