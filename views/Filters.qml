import QtQuick
import qs.services
import qs.kit

// The bar under the head while a search is open: names or the text inside files, then the kinds found, each a chip
// with its count. A chip narrows the results to its kind; All shows them again. The place searched sits at the end.
Item {
    id: root
    required property var browser
    readonly property var folder: root.browser.activePane ? root.browser.activePane.folder : null
    readonly property bool searching: !!root.folder && root.folder.mode === "search"
    readonly property bool shown: !!root.folder && (root.searching || root.browser.head.searchOpen)
    implicitHeight: Theme.dp(46)

    readonly property var kinds: [
        { key: "", text: I18n.tr("All"), glyph: "" },
        { key: "folder", text: I18n.tr("Folders"), glyph: "folder" },
        { key: "document", text: I18n.tr("Documents"), glyph: "description" },
        { key: "image", text: I18n.tr("Images"), glyph: "image" },
        { key: "video", text: I18n.tr("Videos"), glyph: "movie" },
        { key: "audio", text: I18n.tr("Audio"), glyph: "music_note" },
        { key: "archive", text: I18n.tr("Archives"), glyph: "folder_zip" },
        { key: "code", text: I18n.tr("Code"), glyph: "code" },
        { key: "other", text: I18n.tr("Other"), glyph: "draft" }
    ]

    component Chip: Item {
        id: chip
        required property var modelData
        readonly property string key: chip.modelData.key
        readonly property int count: !root.folder ? 0 : chip.key === "" ? root.folder.found.length : (root.folder.kindCounts[chip.key] ?? 0)
        readonly property bool on: !!root.folder && root.folder.kindFilter === chip.key
        // A kind with nothing found stays away, unless it is the one asked for.
        visible: root.searching && (chip.on || chip.count > 0)
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        width: body.implicitWidth + Theme.dp(chip.modelData.glyph ? 22 : 26)
        height: Theme.dp(32)
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: chip.on ? Theme.accentPlate : chipMouse.pressed ? Theme.fillPress : chipMouse.containsMouse ? Theme.fill : "transparent"
            border.width: chip.on ? 0 : 1
            border.color: Theme.line
            Behavior on color { ColorAnimation { duration: Theme.fast } }
        }
        Row {
            id: body
            anchors.centerIn: parent
            spacing: Theme.dp(6)
            Glyph {
                visible: chip.modelData.glyph.length > 0
                anchors.verticalCenter: parent.verticalCenter
                name: chip.modelData.glyph
                size: Theme.dp(16)
                fill: chip.on ? 1 : 0
                color: chip.on ? Theme.accentInk : Theme.ink2
            }
            Txt {
                anchors.verticalCenter: parent.verticalCenter
                text: chip.modelData.text
                size: Theme.small
                strong: chip.on
                color: chip.on ? Theme.accentInk : Theme.ink
            }
            Txt {
                anchors.verticalCenter: parent.verticalCenter
                text: Fmt.num(chip.count, 0)
                size: Theme.small
                color: chip.on ? Theme.accentInk : Theme.ink3
                font.features: { "tnum": 1 }
            }
        }
        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.folder.filterKind(chip.on ? "" : chip.key)
        }
    }

    Segments {
        id: what
        x: Theme.dp(14)
        anchors.verticalCenter: parent.verticalCenter
        value: root.folder && root.folder.content ? "content" : "name"
        options: [
            { value: "name", text: I18n.tr("Names"), tip: I18n.tr("Search names") },
            { value: "content", text: I18n.tr("Contents"), tip: I18n.tr("Search inside files") }
        ]
        onChosen: value => { if (root.folder) root.folder.content = value === "content" }
    }
    Rectangle {
        id: rule
        visible: root.searching
        anchors.left: what.right
        anchors.leftMargin: Theme.dp(10)
        anchors.verticalCenter: parent.verticalCenter
        width: 1
        height: Theme.dp(20)
        color: Theme.line
    }
    // The chips that do not fit slide under the wheel or the touchpad.
    Item {
        id: lane
        anchors.left: rule.right
        anchors.leftMargin: Theme.dp(10)
        anchors.right: scope.visible ? scope.left : parent.right
        anchors.rightMargin: Theme.dp(12)
        height: parent.height
        clip: true
        property real offset: 0
        readonly property real room: Math.max(0, chips.width - lane.width)
        onRoomChanged: lane.offset = Math.min(lane.offset, lane.room)
        // Under the chips: a chip passes the wheel on, a click stays the chip's.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            enabled: lane.room > 0
            onWheel: wheel => {
                const px = wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.pixelDelta.x
                const d = px !== 0 ? px : (wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x) / 2
                lane.offset = Math.max(0, Math.min(lane.room, lane.offset - d))
            }
        }
        Row {
            id: chips
            x: -lane.offset
            height: lane.height
            spacing: Theme.dp(6)
            move: Transition { NumberAnimation { properties: "x"; duration: Theme.fast; easing.type: Easing.OutCubic } }
            Repeater { model: root.kinds; delegate: Chip {} }
        }
    }
    // A cut edge fades out, so the chips past it read as more to see, not as missing.
    Rectangle {
        visible: lane.offset > 0
        anchors.left: lane.left
        width: Theme.dp(28)
        height: lane.height
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: Theme.canvas }
            GradientStop { position: 1; color: Theme.alpha(Theme.canvas, 0) }
        }
    }
    Rectangle {
        visible: lane.offset < lane.room
        anchors.right: lane.right
        width: Theme.dp(28)
        height: lane.height
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: Theme.alpha(Theme.canvas, 0) }
            GradientStop { position: 1; color: Theme.canvas }
        }
    }
    Txt {
        id: scope
        visible: root.searching && root.width > Theme.dp(720)
        anchors.right: parent.right
        anchors.rightMargin: Theme.dp(16)
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, root.width * 0.28)
        text: root.folder ? I18n.tr("In %1", Fmt.pretty(root.folder.searchRoot)) : ""
        size: Theme.small
        color: Theme.ink3
        elide: Text.ElideMiddle
    }
}
