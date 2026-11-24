import QtQuick
import QtQuick.Controls.Basic as QQC
import qs.services
import qs.kit

// The way down as columns side by side: each folder above the one on screen, the one on screen, and what the chosen
// folder holds. A click in any column makes that column the place and chooses what was clicked. A column is kept while
// its folder stays on the way, and a folder read once shows at once when it comes back: a step left or right moves the
// columns, it does not build them again. Things dragged from any column drop on a folder row or on a column's ground.
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

    // The folder the columns are laid out for. It moves once the folder's new reading is in place, so the columns, the
    // one on screen and the one it opens all change in the same frame.
    property string shown: ""
    readonly property bool settled: root.shown === root.folder.path && !root.folder.loading

    function under(path: string, top: string): bool { return path === top || path.startsWith(top.endsWith("/") ? top : top + "/") }
    readonly property string base: root.folder.mode !== "folder" ? "" : (root.under(root.shown, Core.home) ? Core.home : "/")
    readonly property var trail: {
        if (root.folder.mode !== "folder" || root.shown.length === 0 || root.shown === root.base) return []
        const out = []
        let p = Fmt.parent(root.shown)
        for (let guard = 0; guard < 64; guard++) {
            out.unshift(p)
            if (p === root.base || p === "/") break
            p = Fmt.parent(p)
        }
        return out
    }
    // Columns for the folders above, kept by path: only those past the first change are made or let go.
    ListModel { id: trailModel }
    onTrailChanged: {
        const want = root.trail
        let k = 0
        while (k < trailModel.count && k < want.length && trailModel.get(k).path === want[k]) k++
        if (trailModel.count > k) trailModel.remove(k, trailModel.count - k)
        for (let i = k; i < want.length; i++) trailModel.append({ path: want[i] })
    }

    readonly property var single: { void root.folder.selRev; return root.folder.selCount === 1 ? root.folder.chosen()[0] ?? null : null }
    readonly property string livePeek: root.single && root.single.dir ? root.single.path : ""
    // While the folder is being read, the column it opened stays: no column closes and opens again on the way.
    property string heldPeek: ""
    onLivePeekChanged: if (root.settled) root.heldPeek = root.livePeek
    onSettledChanged: if (root.settled) root.heldPeek = root.livePeek
    readonly property string peek: root.settled ? root.livePeek : root.heldPeek

    // Folders read lately, by path, so a column that comes back shows its rows before the disk is read again.
    property var cache: ({})
    function keep(path: string, rows: var): void {
        const c = root.cache
        delete c[path]
        c[path] = rows
        const keys = Object.keys(c)
        if (keys.length > 48) delete c[keys[0]]
    }
    function seed(path: string): var { return root.cache[path] ?? null }

    // A menu asked for in a column that is not the place opens once that column is the place, on what was clicked.
    property var menuAt: null
    Connections {
        target: root.folder
        function onApplied() {
            const f = root.folder
            if (f.mode === "folder" && f.error.length === 0) root.keep(f.path, f.all)
            root.shown = f.path
            if (root.menuAt) {
                const p = root.menuAt
                root.menuAt = null
                root.pane.browser.actions.itemMenu(root.pane, p.x, p.y)
            }
        }
    }
    Component.onCompleted: if (!root.folder.loading) root.shown = root.folder.path

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
        const f = root.folder
        if (f.mode === "folder" && f.path === dir && !f.loading) {
            const i = f.indexOf(path)
            if (i >= 0) f.only(i)
            return
        }
        f.focusPath = path
        f.go(dir)
    }
    function pickWithMenu(dir: string, path: string, from: Item, x: real, y: real): void {
        const p = from.mapToItem(root.pane.browser.stage, x, y)
        const f = root.folder
        if (f.mode === "folder" && f.path === dir && !f.loading) {
            root.pick(dir, path)
            root.pane.browser.actions.itemMenu(root.pane, p.x, p.y)
            return
        }
        root.menuAt = p
        root.pick(dir, path)
    }

    // What a column says when it has no rows to show.
    function blankText(error: string, empty: bool): string {
        if (error === "denied") return I18n.tr("No permission to open this folder")
        if (error === "missing") return I18n.tr("This folder no longer exists")
        if (error.length > 0) return I18n.tr("This place could not be read")
        return empty ? I18n.tr("This folder is empty") : ""
    }

    component Entry: Item {
        id: row
        required property var entry
        property bool on: false
        property bool strong: false
        property bool joinUp: false
        property bool joinDown: false
        property bool editing: false
        property bool dropping: false
        readonly property alias icon: rowIcon
        signal pressed(var mouse, Item from)
        signal released(var mouse)
        signal opened()
        signal held(point at, Item from)
        // A drag rested on this folder long enough to open it.
        signal sprung()
        width: root.colWidth
        height: root.rowHeight
        // Rows are kept and handed to other entries as a column scrolls: one leaves with nothing of the last entry's.
        ListView.onPooled: { row.dropping = false; spring.stop() }
        Rectangle {
            readonly property real r: Theme.dp(8)
            anchors.fill: parent
            anchors.leftMargin: Theme.dp(5)
            anchors.rightMargin: Theme.dp(5)
            topLeftRadius: row.joinUp ? 0 : r
            topRightRadius: row.joinUp ? 0 : r
            bottomLeftRadius: row.joinDown ? 0 : r
            bottomRightRadius: row.joinDown ? 0 : r
            color: row.dropping ? Theme.selectionHover : row.on ? (row.strong ? (rowMouse.containsMouse ? Theme.selectionHover : Theme.selection) : Theme.fillPress) : rowMouse.pressed ? Theme.fillPress : rowMouse.containsMouse ? Theme.fill : "transparent"
            border.width: row.dropping ? Math.max(1, Theme.dp(1.5)) : 0
            border.color: Theme.accent
        }
        FileIcon {
            id: rowIcon
            x: Theme.dp(12)
            y: Math.round((parent.height - height) / 2)
            size: root.iconSize
            entry: row.entry
        }
        Txt {
            visible: !row.editing
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
            enabled: !row.editing
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            drag.target: proxy
            drag.threshold: Theme.dp(8)
            drag.onActiveChanged: { if (drag.active) root.pane.carry(); else { proxy.x = 0; proxy.y = 0 } }
            onPressed: mouse => row.pressed(mouse, rowMouse)
            onReleased: mouse => { if (!drag.active) row.released(mouse) }
            onDoubleClicked: mouse => { if (mouse.button === Qt.LeftButton) row.opened() }
            Hold { onHeld: at => row.held(at, rowMouse) }
        }
        // What the press moves past the threshold; the drag itself rides on the pane.
        Item { id: proxy }
        DropArea {
            anchors.fill: parent
            enabled: row.entry.dir
            onEntered: drag => {
                if (!drag.hasUrls || root.pane.browser.actions.dropRefused(drag.urls, row.entry.path)) { drag.accepted = false; return }
                row.dropping = true
                spring.restart()
            }
            onExited: { row.dropping = false; spring.stop() }
            onDropped: drop => { row.dropping = false; spring.stop(); root.pane.browser.actions.drop(drop, row.entry.path) }
        }
        Timer {
            id: spring
            interval: 900
            onTriggered: { row.dropping = false; row.sprung() }
        }
    }

    // A column's ground: what lands on it goes into the column's folder.
    component Ground: DropArea {
        id: ground
        property string dest: ""
        property bool hover: false
        onEntered: drag => {
            if (!drag.hasUrls || ground.dest.length === 0 || root.pane.browser.actions.dropRefused(drag.urls, ground.dest)) { drag.accepted = false; return }
            ground.hover = true
        }
        onExited: ground.hover = false
        onDropped: drop => { ground.hover = false; root.pane.browser.actions.drop(drop, ground.dest) }
        Rectangle {
            anchors.fill: parent
            anchors.margins: Theme.dp(3)
            visible: ground.hover
            radius: Theme.round(8)
            color: Theme.alpha(Theme.accent, 0.06)
            border.width: Math.max(1, Theme.dp(1.5))
            border.color: Theme.alpha(Theme.accent, 0.7)
        }
    }

    component Side: Item {
        id: side
        required property string path
        property string next: ""
        readonly property bool ready: listing.ready
        width: root.colWidth
        height: strip.height
        // A column fades in once it has something to show, rather than opening blank and filling a moment later.
        opacity: side.ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
        Listing {
            id: listing
            path: side.path
            seedOf: root.seed
            onLoaded: rows => { root.keep(side.path, rows); Qt.callLater(side.showNext) }
        }
        // The row on the way down stays in sight.
        function showNext(): void {
            const i = listing.rows.findIndex(e => e.path === side.next)
            if (i >= 0) list.positionViewAtIndex(i, ListView.Contain)
        }
        onNextChanged: Qt.callLater(side.showNext)
        Component.onCompleted: Qt.callLater(side.showNext)
        Ground { anchors.fill: parent; dest: side.path }
        ListView {
            id: list
            anchors.fill: parent
            anchors.topMargin: Theme.dp(6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            reuseItems: true
            model: listing.model
            delegate: Entry {
                id: sideRow
                required property var model
                entry: model
                on: model.path === side.next
                onPressed: (mouse, from) => {
                    if (mouse.button === Qt.RightButton) { root.pickWithMenu(side.path, model.path, from, mouse.x, mouse.y); return }
                    if (mouse.button === Qt.LeftButton) {
                        root.pane.activate()
                        root.pane.held = false
                        root.pane.ready(sideRow.icon, root.iconSize, [model.path])
                    }
                }
                // The place moves on the click, not the press, so a press can still become a drag.
                onReleased: mouse => {
                    if (root.pane.held) { root.pane.held = false; return }
                    if (mouse.button === Qt.MiddleButton) { if (model.dir) root.pane.browser.newTab(model.path); return }
                    if (mouse.button !== Qt.LeftButton) return
                    root.pick(side.path, model.path)
                    if (Prefs.get("singleClick") && !model.dir) root.pane.browser.actions.open(root.pane, [model])
                }
                onOpened: if (!Prefs.get("singleClick") && !model.dir) root.pane.browser.actions.open(root.pane, [model])
                onHeld: (at, from) => {
                    if (root.pane.browser.busy) return
                    root.pane.held = true
                    root.pickWithMenu(side.path, model.path, from, at.x, at.y)
                }
                onSprung: root.pick(side.path, model.path)
            }
            QQC.ScrollBar.vertical: Scroller {}
        }
        Caption {
            visible: listing.ready && listing.rows.length === 0
            x: Theme.dp(16)
            y: Theme.dp(14)
            width: parent.width - Theme.dp(32)
            wrapMode: Text.Wrap
            strong: false
            text: root.blankText(listing.error, true)
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
        // The folder in view stays in view: a column that opens or closes slides the strip; a change of width does
        // not wait.
        property bool placed: false
        function toEnd(glide: bool): void {
            const to = Math.max(0, strip.contentWidth - strip.width)
            if (Math.abs(to - strip.contentX) >= 1) {
                if (glide && strip.placed && Theme.motion) { slide.to = to; slide.restart() }
                else { slide.stop(); strip.contentX = to }
            }
            if (strip.width > 0) strip.placed = true
        }
        onContentWidthChanged: Qt.callLater(strip.toEnd, true)
        onWidthChanged: Qt.callLater(strip.toEnd, false)
        NumberAnimation { id: slide; target: strip; property: "contentX"; duration: Theme.normal; easing.type: Easing.OutCubic }
        QQC.ScrollBar.horizontal: Scroller { orientation: Qt.Horizontal }

        Item {
            id: lane
            readonly property bool peekShown: peekLoader.item !== null && peekLoader.item.ready
            width: root.colWidth * (trailModel.count + 1 + (lane.peekShown ? 1 : 0))
            height: strip.height

            Repeater {
                model: trailModel
                delegate: Side {
                    required property int index
                    x: index * root.colWidth
                    next: root.trail[index + 1] ?? root.shown
                }
            }

            Item {
                id: here
                x: trailModel.count * root.colWidth
                width: root.colWidth
                height: lane.height
                Ground {
                    anchors.fill: parent
                    enabled: root.folder.mode === "folder" && root.folder.writable
                    dest: root.folder.path
                }
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
                    reuseItems: true
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
                        editing: root.pane.browser.renaming === model.path
                        onPressed: (mouse, from) => {
                            root.pane.pressItem(hereRow.index, mouse, from)
                            if (mouse.button === Qt.LeftButton) root.pane.ready(hereRow.icon, root.iconSize)
                        }
                        onReleased: mouse => {
                            if (mouse.button === Qt.MiddleButton) root.pane.openItem(hereRow.index, true)
                            else root.pane.releaseItem(hereRow.index, mouse)
                        }
                        onOpened: if (!Prefs.get("singleClick")) root.pane.openItem(hereRow.index, false)
                        onHeld: (at, from) => root.pane.holdItem(hereRow.index, at, from)
                        onSprung: root.folder.only(hereRow.index)
                        Loader {
                            active: hereRow.editing
                            anchors.verticalCenter: parent.verticalCenter
                            x: Theme.dp(34)
                            width: parent.width - Theme.dp(44)
                            sourceComponent: NameEdit {
                                name: hereRow.model.name
                                onDone: name => root.pane.browser.actions.renameTo(hereRow.model.path, name)
                                onCancelled: root.pane.browser.actions.renameCancelled(root.pane)
                            }
                        }
                    }
                    QQC.ScrollBar.vertical: Scroller {}
                }
                Caption {
                    visible: root.settled && current.count === 0
                    x: Theme.dp(16)
                    y: Theme.dp(14)
                    width: parent.width - Theme.dp(32)
                    wrapMode: Text.Wrap
                    strong: false
                    text: root.folder.mode === "folder" ? root.blankText(root.folder.error, true) : ""
                }
                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
            }

            Loader {
                id: peekLoader
                active: root.peek.length > 0
                x: (trailModel.count + 1) * root.colWidth
                sourceComponent: Side { path: root.peek }
            }
        }
    }
}
