import QtQuick
import qs.services
import qs.kit

// One entry of the grid: its picture over its name. Chosen, the picture and the name sit on the selection's tint. A folder takes what is dropped on it and opens when a drag rests over it.
Item {
    id: root
    required property int index
    required property var model
    required property string path
    required property string name
    required property bool dir
    property var pane
    property real iconSize: 72

    readonly property var folder: root.pane.folder
    readonly property bool chosen: { void root.folder.selRev; return root.folder.isSel(root.path) }
    readonly property bool focused: root.pane.activeFocus && root.folder.current === root.index && !root.chosen
    readonly property bool lit: root.pane.active
    readonly property bool renaming: root.pane.browser.renaming === root.path
    readonly property bool cut: { void root.pane.browser.actions.clipRev; return root.pane.browser.actions.isCut(root.path) }
    readonly property bool hovered: hit.containsMouse && root.inside(hit.mouseX, hit.mouseY)
    property bool dropping: false
    property string uris: ""

    z: root.chosen || root.renaming ? 2 : 0

    function inside(x: real, y: real): bool {
        const inPlate = x >= plate.x && x <= plate.x + plate.width && y >= plate.y && y <= plate.y + plate.height
        const inName = x >= pill.x && x <= pill.x + pill.width && y >= pill.y && y <= pill.y + pill.height
        return inPlate || inName
    }

    Rectangle {
        id: plate
        x: Math.round((parent.width - width) / 2)
        y: Theme.dp(4)
        width: root.iconSize + Theme.dp(18)
        height: width
        radius: Math.min(Theme.dp(16), width * 0.18)
        color: root.dropping ? Theme.selectionHover : root.chosen ? (root.lit ? (root.hovered ? Theme.selectionHover : Theme.selection) : Theme.fillPress) : root.hovered ? Theme.fill : "transparent"
        border.width: root.dropping || root.focused ? Math.max(1, Theme.dp(1.5)) : 0
        border.color: root.dropping ? Theme.accent : Theme.alpha(Theme.accent, 0.55)
        Behavior on color { ColorAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
    }

    // On whole pixels: a picture or a drawn sheet half a pixel off is resampled soft.
    FileIcon {
        id: icon
        x: plate.x + Math.round((plate.width - width) / 2)
        y: plate.y + Math.round((plate.height - height) / 2)
        size: root.iconSize
        entry: root.model
        dim: root.cut
        scale: root.dropping ? 1.06 : 1
        Behavior on scale { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
    }

    Rectangle {
        id: pill
        visible: !root.renaming
        x: label.x + (label.width - label.contentWidth) / 2 - Theme.dp(6)
        y: label.y - Theme.dp(2)
        width: label.contentWidth + Theme.dp(12)
        height: label.contentHeight + Theme.dp(4)
        radius: Math.min(Theme.dp(8), height / 2)
        color: root.chosen ? (root.lit ? (root.hovered ? Theme.selectionHover : Theme.selection) : Theme.fillPress) : "transparent"
    }
    Txt {
        id: label
        visible: !root.renaming
        anchors.horizontalCenter: parent.horizontalCenter
        y: plate.y + plate.height + Theme.dp(5)
        width: root.width - Theme.dp(16)
        text: root.name
        size: Theme.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        maximumLineCount: root.chosen && root.folder.selCount === 1 ? 5 : 2
        elide: Text.ElideRight
        color: Theme.ink
        opacity: root.cut ? 0.6 : 1
    }

    Loader {
        active: root.renaming
        anchors.horizontalCenter: parent.horizontalCenter
        y: label.y - Theme.dp(3)
        width: Math.max(root.width - Theme.dp(6), Theme.dp(120))
        sourceComponent: NameEdit {
            name: root.name
            centered: true
            onDone: name => root.pane.browser.actions.renameTo(root.path, name)
            onCancelled: root.pane.browser.actions.renameCancelled(root.pane)
        }
    }

    MouseArea {
        id: hit
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        drag.target: root.renaming ? null : proxy
        drag.threshold: Theme.dp(8)
        cursorShape: root.hovered && Prefs.get("singleClick") ? Qt.PointingHandCursor : Qt.ArrowCursor
        onPressed: mouse => {
            if (!root.inside(mouse.x, mouse.y) || root.renaming) { mouse.accepted = false; return }
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
        x: plate.x
        y: plate.y
        width: plate.width
        height: plate.height
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
            proxy.x = plate.x
            proxy.y = plate.y
        }
    }

    DropArea {
        x: plate.x
        y: plate.y
        width: plate.width
        height: pill.y + pill.height - plate.y
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
