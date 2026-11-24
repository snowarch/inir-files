import QtQuick
import qs.services
import qs.kit

// The line under the panes: how much the place holds and what is chosen, the room left on its disk, the jobs at work
// and the size of what is shown.
Item {
    id: root
    required property var browser
    readonly property var pane: root.browser.activePane
    readonly property var folder: root.pane ? root.pane.folder : null
    implicitHeight: Theme.dp(36)

    readonly property string summary: {
        const f = root.folder
        if (!f) return ""
        void f.selRev
        const count = f.model.count
        if (f.selCount > 0) {
            const chosen = f.chosen()
            const files = chosen.filter(e => !e.dir)
            const bytes = files.reduce((a, e) => a + e.size, 0)
            let text = I18n.tr("%1 of %2 chosen", Fmt.num(f.selCount, 0), Fmt.num(count, 0))
            if (files.length > 0) text += " · " + Fmt.size(bytes)
            if (f.selCount === 1 && chosen[0]) text = chosen[0].name + " · " + (chosen[0].dir ? (chosen[0].items >= 0 ? Fmt.items(chosen[0].items) : I18n.tr("Folder")) : Fmt.size(chosen[0].size))
            return text
        }
        if (f.mode === "start") {
            const rootDisk = (Core.places.devices ?? []).find(d => d.root)
            return rootDisk && rootDisk.size > 0 ? I18n.tr("%1 free of %2", Fmt.size(rootDisk.free), Fmt.size(rootDisk.size)) : ""
        }
        if (f.mode === "search") {
            const found = f.kindFilter.length > 0 ? I18n.tr("%1 of %2 results", Fmt.num(count, 0), Fmt.num(f.found.length, 0)) : I18n.n("%1 result", "%1 results", count)
            return (f.searching ? I18n.tr("Searching · ") : "") + found
        }
        let text = Fmt.items(count)
        if (f.hiddenCount > 0 && !f.showHidden) text += " · " + I18n.n("%1 hidden", "%1 hidden", f.hiddenCount)
        return text
    }

    Rectangle { width: parent.width; height: 1; color: Theme.line }

    Txt {
        anchors.left: parent.left
        anchors.leftMargin: Theme.dp(16)
        anchors.right: right.left
        anchors.rightMargin: Theme.dp(12)
        anchors.verticalCenter: parent.verticalCenter
        text: root.summary
        size: Theme.small
        color: Theme.ink2
        elide: Text.ElideMiddle
    }

    Row {
        id: right
        anchors.right: parent.right
        anchors.rightMargin: Theme.dp(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.dp(12)

        Jobs {
            browser: root.browser
            anchors.verticalCenter: parent.verticalCenter
        }
        Row {
            visible: root.folder && root.folder.space.total > 0 && root.folder.mode === "folder"
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(7)
            Meter {
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.dp(44)
                value: root.folder && root.folder.space.total > 0 ? 1 - root.folder.space.free / root.folder.space.total : 0
            }
            Txt {
                anchors.verticalCenter: parent.verticalCenter
                text: root.folder ? I18n.tr("%1 free", Fmt.size(root.folder.space.free)) : ""
                size: Theme.small
                color: Theme.ink2
            }
        }
        // The size of what is shown: pictures in the grid, rows in the list.
        Item {
            id: zoom
            visible: !!root.pane && (!root.folder || root.folder.mode !== "start")
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.dp(110)
            height: Theme.dp(24)
            readonly property bool grid: root.pane && (root.pane.viewMode === "grid" || root.pane.viewMode === "gallery")
            readonly property int lo: zoom.grid ? 1 : 0
            readonly property int hi: zoom.grid ? 7 : 2
            readonly property int value: root.pane ? (zoom.grid ? root.pane.zoom : root.pane.listZoom) : zoom.lo
            function set(v: int): void { if (root.pane) root.pane.setZoom(v) }
            Glyph { id: zlo; anchors.verticalCenter: parent.verticalCenter; name: zoom.grid ? "photo_size_select_small" : "density_small"; size: Theme.dp(15); color: Theme.ink3 }
            Item {
                id: track
                anchors.left: zlo.right
                anchors.leftMargin: Theme.dp(6)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                readonly property real frac: (zoom.value - zoom.lo) / Math.max(1, zoom.hi - zoom.lo)
                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: Theme.dp(4); radius: height / 2; color: Theme.fillPress }
                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: Math.max(height, parent.width * track.frac); height: Theme.dp(4); radius: height / 2; color: Theme.accent }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    x: (parent.width - width) * track.frac
                    width: Theme.dp(14)
                    height: width
                    radius: width / 2
                    color: Theme.light ? "#ffffff" : Theme.mix(Theme.high, Theme.ink, 0.25)
                    border.width: 1
                    border.color: Theme.line
                    Behavior on x { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
                }
                MouseArea {
                    anchors.fill: parent
                    function at(x: real): void { zoom.set(zoom.lo + Math.round(Math.max(0, Math.min(1, x / width)) * (zoom.hi - zoom.lo))) }
                    onPressed: mouse => at(mouse.x)
                    onPositionChanged: mouse => { if (pressed) at(mouse.x) }
                    onWheel: wheel => zoom.set(zoom.value + (wheel.angleDelta.y > 0 ? 1 : -1))
                }
            }
        }
    }
}
