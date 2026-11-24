import QtQuick
import qs.services
import qs.kit

// One entry of the gallery: a square of its picture, cropped to fill, with no name. What has no picture of its own
// keeps its art and its name, so a folder or a document can still be told apart. Chosen, the picture draws back from
// the edges onto the selection's tint and wears a check; under the pointer, the ring in the corner chooses it alone.
Item {
    id: root
    required property int index
    required property var model
    required property string path
    required property string name
    required property bool dir
    property var pane
    property real gap: 4

    readonly property var folder: root.pane.folder
    readonly property bool chosen: { void root.folder.selRev; return root.folder.isSel(root.path) }
    readonly property bool focused: root.pane.activeFocus && root.folder.current === root.index && !root.chosen
    readonly property bool lit: root.pane.active
    readonly property bool renaming: root.pane.browser.renaming === root.path
    readonly property bool cut: { void root.pane.browser.actions.clipRev; return root.pane.browser.actions.isCut(root.path) }
    readonly property bool hovered: hit.containsMouse
    // Photos and films fill their square; anything else is drawn whole, over its name.
    readonly property bool media: !root.dir && (root.model.kind === "image" || root.model.kind === "video") && Core.wantsThumb(root.model)
    readonly property real side: Math.max(0, root.width - root.gap)
    readonly property real ring: Math.round(Math.max(Theme.dp(18), Math.min(Theme.dp(24), root.side * 0.15)))
    property bool dropping: false

    z: root.renaming ? 2 : 0
    // Tiles are kept and handed to other entries as the gallery scrolls: one leaves with nothing of the last entry's.
    GridView.onPooled: { root.dropping = false; spring.stop() }

    // The corner that chooses a tile and keeps the rest of the choice: the ring and a margin round it.
    function onRing(x: real, y: real): bool {
        const reach = tile.x + Theme.dp(6) + root.ring + Theme.dp(6)
        return x <= reach && y <= reach
    }

    Rectangle {
        id: tile
        x: root.gap / 2
        y: root.gap / 2
        width: root.side
        height: root.side
        color: root.dropping ? Theme.selectionHover : root.chosen ? (root.lit ? Theme.selection : Theme.fillPress) : root.hovered && !root.media ? Theme.fillPress : Theme.fill
        Behavior on color { ColorAnimation { duration: Theme.hoverMs; easing.type: Easing.OutCubic } }

        Item {
            id: content
            anchors.fill: parent
            // Chosen, or waiting for a drop, the picture draws back and the tint shows round it.
            scale: root.chosen ? 0.86 : root.dropping ? 0.93 : 1
            Behavior on scale { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }

            // On whole pixels: a picture half a pixel off is resampled soft.
            FileIcon {
                id: icon
                x: Math.round((parent.width - width) / 2)
                y: root.media ? 0 : Math.round(parent.height * (label.visible ? 0.4 : 0.5) - height / 2)
                size: root.media ? root.side : Math.round(root.side * 0.44)
                crop: root.media
                entry: root.model
                dim: root.cut
            }
            Txt {
                id: label
                visible: !root.media && !root.renaming
                x: Theme.dp(8)
                y: icon.y + icon.height + Theme.dp(6)
                width: parent.width - Theme.dp(16)
                text: root.name
                // A small tile keeps one line of the name, so a folder can still be told apart.
                size: root.side >= Theme.dp(88) ? Theme.small : Theme.caption
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: root.side >= Theme.dp(88) ? 2 : 1
                elide: Text.ElideRight
                color: Theme.ink
                opacity: root.cut ? 0.6 : 1
            }
        }

        // The keyboard's place, and a folder a drag rests on.
        Rectangle {
            anchors.fill: parent
            visible: root.focused || root.dropping
            color: "transparent"
            border.width: Math.max(1, Theme.dp(2))
            border.color: root.dropping ? Theme.accent : Theme.alpha(Theme.accent, 0.7)
        }

        Rectangle {
            visible: root.chosen || (root.hovered && !root.renaming)
            x: Theme.dp(6)
            y: Theme.dp(6)
            width: root.ring
            height: width
            radius: width / 2
            color: root.chosen ? Theme.accent : Qt.rgba(0, 0, 0, 0.3)
            border.width: root.chosen ? 0 : Math.max(1, Theme.dp(1.5))
            border.color: "#ffffff"
            Glyph {
                visible: root.chosen
                anchors.centerIn: parent
                name: "check"
                size: parent.width * 0.74
                weight: 700
                color: Theme.inkAccent
            }
        }
    }

    Loader {
        active: root.renaming
        x: Math.round((root.width - width) / 2)
        y: tile.y + tile.height - height - Theme.dp(4)
        width: Math.max(tile.width - Theme.dp(8), Theme.dp(140))
        sourceComponent: NameEdit {
            name: root.name
            centered: true
            onDone: name => root.pane.browser.actions.renameTo(root.path, name)
            onCancelled: root.pane.browser.actions.renameCancelled(root.pane)
        }
    }

    MouseArea {
        id: hit
        anchors.fill: tile
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        property bool ringPress: false
        drag.target: root.renaming || hit.ringPress ? null : proxy
        drag.threshold: Theme.dp(8)
        drag.onActiveChanged: { if (drag.active) root.pane.carry(); else { proxy.x = 0; proxy.y = 0 } }
        cursorShape: Prefs.get("singleClick") ? Qt.PointingHandCursor : Qt.ArrowCursor
        onPressed: mouse => {
            if (root.renaming) { mouse.accepted = false; return }
            hit.ringPress = mouse.button === Qt.LeftButton && (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) === 0 && root.onRing(mouse.x + tile.x, mouse.y + tile.y)
            if (hit.ringPress) {
                root.pane.activate()
                root.folder.toggle(root.index)
                return
            }
            root.pane.pressItem(root.index, mouse, hit)
            if (mouse.button === Qt.LeftButton) root.pane.ready(icon, icon.width)
        }
        onReleased: mouse => {
            if (hit.ringPress) { hit.ringPress = false; return }
            if (!drag.active) root.pane.releaseItem(root.index, mouse)
        }
        onDoubleClicked: mouse => { if (mouse.button === Qt.LeftButton && !hit.ringPress && !Prefs.get("singleClick")) root.pane.openItem(root.index, false) }
        onClicked: mouse => { if (mouse.button === Qt.MiddleButton) root.pane.openItem(root.index, true) }
        Hold { onHeld: at => { if (!root.renaming) root.pane.holdItem(root.index, at, hit) } }
    }

    // What the press moves past the threshold; the drag itself rides on the pane.
    Item { id: proxy }

    DropArea {
        anchors.fill: tile
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
