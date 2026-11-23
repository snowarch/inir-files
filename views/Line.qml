import QtQuick
import qs.services
import qs.kit

// One entry of the list: its picture and name, then the columns the place shows. Chosen, the row takes the selection's
// tint; chosen rows next to each other join into one plate, rounded only at its ends.
Item {
    id: root
    required property int index
    required property var model
    required property string path
    required property string name
    required property bool dir
    required property real size
    required property real mtime
    required property int items
    required property string comment
    required property string origin
    required property real deleted
    required property string snippet
    required property string target
    required property bool link
    property var pane
    property var columns: []
    property real iconSize: Theme.dp(20)

    readonly property var folder: root.pane.folder
    readonly property bool chosen: { void root.folder.selRev; return root.folder.isSel(root.path) }
    readonly property bool focused: root.pane.activeFocus && root.folder.current === root.index && !root.chosen
    readonly property bool lit: root.pane.active
    readonly property bool renaming: root.pane.browser.renaming === root.path
    readonly property bool cut: { void root.pane.browser.actions.clipRev; return root.pane.browser.actions.isCut(root.path) }
    readonly property real nameWidth: root.columns.length > 0 ? root.columns[0].width : root.width
    readonly property bool hovered: hit.containsMouse
    readonly property bool joinUp: { void root.folder.selRev; const e = root.folder.all[root.index - 1]; return root.chosen && !!e && root.folder.isSel(e.path) }
    readonly property bool joinDown: { void root.folder.selRev; const e = root.folder.all[root.index + 1]; return root.chosen && !!e && root.folder.isSel(e.path) }
    property bool dropping: false
    property string uris: ""

    function value(key: string): string {
        switch (key) {
        case "size": return root.dir ? (root.items >= 0 ? Fmt.items(root.items) : "") : Fmt.size(root.size)
        case "mtime": return Fmt.when(root.mtime)
        case "kind": return root.comment.length > 0 ? root.comment : root.model.kind
        case "origin": return Fmt.pretty(Fmt.parent(root.origin))
        case "deleted": return Fmt.when(root.deleted)
        case "where": {
            // Below the place searched, the way down from it reads shorter than the whole path.
            const dir = Fmt.parent(root.path)
            const top = root.folder.searchRoot
            if (root.folder.mode !== "search" || top.length === 0 || (dir !== top && !dir.startsWith(top.endsWith("/") ? top : top + "/"))) return Fmt.pretty(dir)
            const head = top === "/" ? "/" : Fmt.name(top)
            const rest = dir.slice(top.length).replace(/^\//, "")
            return rest.length === 0 ? head : (head.endsWith("/") ? head : head + "/") + rest
        }
        case "snippet": return root.snippet
        }
        return ""
    }

    Rectangle {
        readonly property real r: Theme.dp(8)
        anchors.fill: parent
        anchors.leftMargin: Theme.dp(6)
        anchors.rightMargin: Theme.dp(6)
        topLeftRadius: root.joinUp ? 0 : r
        topRightRadius: root.joinUp ? 0 : r
        bottomLeftRadius: root.joinDown ? 0 : r
        bottomRightRadius: root.joinDown ? 0 : r
        color: root.dropping ? Theme.selectionHover : root.chosen ? (root.lit ? (root.hovered ? Theme.selectionHover : Theme.selection) : Theme.fillPress) : root.hovered ? Theme.fill : "transparent"
        border.width: root.dropping || root.focused ? Math.max(1, Theme.dp(1.5)) : 0
        border.color: root.dropping ? Theme.accent : Theme.alpha(Theme.accent, 0.55)
    }

    Row {
        x: Theme.dp(6)
        height: parent.height
        Item {
            width: root.nameWidth - Theme.dp(6)
            height: parent.height
            FileIcon {
                id: icon
                x: Theme.dp(10)
                y: Math.round((parent.height - height) / 2)
                size: root.iconSize
                entry: root.model
                dim: root.cut
            }
            Txt {
                id: label
                visible: !root.renaming
                anchors.left: icon.right
                anchors.leftMargin: Theme.dp(10)
                anchors.right: parent.right
                anchors.rightMargin: Theme.dp(8)
                anchors.verticalCenter: parent.verticalCenter
                text: root.name
                size: Theme.row
                color: Theme.ink
                elide: Text.ElideMiddle
                opacity: root.cut ? 0.6 : 1
            }
            Loader {
                active: root.renaming
                anchors.left: icon.right
                anchors.leftMargin: Theme.dp(6)
                anchors.right: parent.right
                anchors.rightMargin: Theme.dp(8)
                anchors.verticalCenter: parent.verticalCenter
                sourceComponent: NameEdit {
                    name: root.name
                    onDone: name => root.pane.browser.actions.renameTo(root.path, name)
                    onCancelled: root.pane.browser.actions.renameCancelled(root.pane)
                }
            }
        }
        Repeater {
            model: root.columns.slice(1)
            delegate: Item {
                required property var modelData
                width: modelData.width
                height: root.height
                Txt {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.dp(10)
                    anchors.rightMargin: Theme.dp(12)
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: modelData.key === "size" ? Text.AlignRight : Text.AlignLeft
                    text: root.value(modelData.key)
                    size: Theme.body
                    color: Theme.ink2
                    font.family: modelData.key === "snippet" ? Theme.mono : Theme.sans
                    font.features: modelData.key === "size" || modelData.key === "mtime" || modelData.key === "deleted" ? { "tnum": 1 } : {}
                    elide: modelData.key === "where" || modelData.key === "origin" ? Text.ElideMiddle : Text.ElideRight
                }
            }
        }
    }

    MouseArea {
        id: hit
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        drag.target: root.renaming ? null : proxy
        drag.threshold: Theme.dp(8)
        onPressed: mouse => {
            // Only the name column takes a press: elsewhere the band starts, as over empty space.
            if (mouse.x > root.nameWidth || root.renaming) { mouse.accepted = false; return }
            root.pane.pressItem(root.index, mouse, hit)
            if (mouse.button === Qt.LeftButton) {
                root.uris = root.folder.chosenPaths().map(p => Fmt.url(p)).join("\r\n")
                icon.grabToImage(r => proxy.Drag.imageSource = r.url)
            }
        }
        onReleased: mouse => { if (!drag.active) root.pane.releaseItem(root.index, mouse) }
        onDoubleClicked: mouse => { if (mouse.button === Qt.LeftButton && !Prefs.get("singleClick")) root.pane.openItem(root.index, false) }
        onClicked: mouse => { if (mouse.button === Qt.MiddleButton) root.pane.openItem(root.index, true) }
    }

    Item {
        id: proxy
        width: root.iconSize
        height: root.iconSize
        Drag.dragType: Drag.Automatic
        Drag.active: hit.drag.active
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
        Drag.proposedAction: Qt.MoveAction
        Drag.hotSpot.x: root.iconSize / 2
        Drag.hotSpot.y: root.iconSize / 2
        Drag.mimeData: ({ "text/uri-list": root.uris })
        Drag.onDragStarted: root.pane.dragging = true
        Drag.onDragFinished: dropAction => {
            root.pane.dragging = false
            proxy.x = 0
            proxy.y = 0
        }
    }

    DropArea {
        width: root.nameWidth
        height: root.height
        enabled: root.dir && root.folder.mode !== "trash"
        onEntered: drag => {
            if (!drag.hasUrls || root.pane.browser.actions.dropRefused(drag.urls, root.path)) { drag.accepted = false; return }
            root.dropping = true
            spring.restart()
        }
        onExited: { root.dropping = false; spring.stop() }
        onDropped: drop => {
            root.dropping = false
            spring.stop()
            root.pane.browser.actions.drop(drop, root.path)
        }
    }
    Timer {
        id: spring
        interval: 900
        onTriggered: { root.dropping = false; root.folder.go(root.path) }
    }
}
