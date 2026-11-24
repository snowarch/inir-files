import QtQuick
import QtQuick.Controls.Basic as QQC
import qs.services
import qs.kit

// Interactive multi-core disk space analyzer: streams per-child sizes on the current filesystem, draws crisp
// proportional bars, lets the person drill into folders, jump to them, or move heavy items straight to the trash.
Sheet {
    id: root
    required property var pane
    property string startPath: ""
    property string path: ""
    property string token: ""
    property bool scanning: false
    property real total: 0
    property var items: []
    property string error: ""
    cardWidth: Theme.dp(600)
    title: I18n.tr("Disk space")
    subtitle: Fmt.pretty(root.path)

    readonly property real maxSize: root.items.length > 0 ? Math.max(1, root.items[0].size) : 1
    readonly property bool canUp: root.path.length > 1 && root.path !== root.startPath

    function analyze(dir: string): void {
        if (root.token.length > 0) Core.call("cancel", { token: root.token })
        root.path = dir
        root.token = "space-" + Math.random().toString(36).slice(2)
        root.items = []
        root.total = 0
        root.error = ""
        root.scanning = true
        Core.call("space_map", { token: root.token, path: dir })
    }
    function goUp(): void {
        if (!root.canUp) return
        root.analyze(Fmt.parent(root.path))
    }
    function stop(): void {
        if (root.token.length > 0) { Core.call("cancel", { token: root.token }); root.token = "" }
        root.scanning = false
    }

    Component.onCompleted: {
        const p = root.startPath.length > 0 ? root.startPath : (root.pane.folder.mode === "folder" ? root.pane.folder.path : Core.home)
        root.startPath = p
        root.analyze(p)
    }
    Component.onDestruction: root.stop()

    Keys.onPressed: event => {
        if ((event.key === Qt.Key_Backspace || (event.key === Qt.Key_Up && (event.modifiers & Qt.AltModifier))) && root.canUp) {
            root.goUp()
            event.accepted = true
        }
    }

    Connections {
        target: Core
        function onSpaceMapEvent(ev) {
            if (ev.token !== root.token) return
            root.total = ev.total ?? 0
            root.items = ev.items ?? []
            if (ev.error) root.error = ev.error
            if (ev.done) root.scanning = false
        }
    }

    // ---- summary strip
    Item {
        width: parent.width
        height: Theme.dp(34)
        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(8)
            Act {
                visible: root.canUp
                anchors.verticalCenter: parent.verticalCenter
                size: Theme.dp(28)
                glyphSize: Theme.dp(17)
                glyph: "arrow_upward"
                tip: I18n.tr("Enclosing folder")
                onClicked: root.goUp()
            }
            Ring {
                visible: root.scanning
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.dp(16)
                height: width
                value: -1
            }
            Txt {
                anchors.verticalCenter: parent.verticalCenter
                text: root.scanning
                    ? I18n.tr("Measuring…") + (root.total > 0 ? " · " + Fmt.size(root.total) : "")
                    : I18n.tr("%1 total · %2", Fmt.size(root.total), Fmt.items(root.items.length))
                size: Theme.body
                strong: !root.scanning
                color: Theme.ink
            }
        }
        Pill {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            glyph: "folder_open"
            text: I18n.tr("Open here")
            onClicked: { root.pane.folder.go(root.path); root.close() }
        }
    }

    // ---- ranked proportional breakdown
    Inset {
        width: parent.width
        height: Math.min(Theme.dp(400), Math.max(Theme.dp(120), root.height - Theme.dp(250)))
        radius: Theme.radius

        ListView {
            id: list
            anchors.fill: parent
            anchors.margins: Theme.dp(6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.items
            QQC.ScrollBar.vertical: Scroller {}

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                readonly property real share: root.total > 0 ? row.modelData.size / root.total : 0
                readonly property real barFrac: Math.max(0.015, row.modelData.size / root.maxSize)
                width: list.width
                height: Theme.dp(46)
                radius: Theme.round(9)
                color: rowHit.pressed ? Theme.fillPress : rowHover.hovered ? Theme.fill : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.hoverMs } }
                HoverHandler { id: rowHover }

                Glyph {
                    id: rGlyph
                    x: Theme.dp(10)
                    y: Theme.dp(10)
                    name: row.modelData.dir ? "folder" : "draft"
                    size: Theme.dp(18)
                    fill: row.modelData.dir ? 1 : 0
                    color: row.modelData.dir ? Theme.folderFront : Theme.ink3
                }
                Txt {
                    anchors.left: rGlyph.right
                    anchors.leftMargin: Theme.dp(9)
                    anchors.right: stats.left
                    anchors.rightMargin: Theme.dp(10)
                    y: Theme.dp(9)
                    text: row.modelData.name
                    size: Theme.row
                    strong: row.index < 3
                    color: Theme.ink
                    elide: Text.ElideMiddle
                }
                Row {
                    id: stats
                    anchors.right: rowActs.visible ? rowActs.left : parent.right
                    anchors.rightMargin: Theme.dp(10)
                    y: Theme.dp(10)
                    spacing: Theme.dp(10)
                    Txt {
                        text: Fmt.size(row.modelData.size)
                        size: Theme.small
                        strong: true
                        color: Theme.ink
                        font.features: { "tnum": 1 }
                    }
                    Txt {
                        width: Theme.dp(36)
                        horizontalAlignment: Text.AlignRight
                        text: Math.round(row.share * 100) + "%"
                        size: Theme.caption
                        color: Theme.ink3
                        font.features: { "tnum": 1 }
                    }
                }
                // Crisp proportional bar along the bottom of the row
                Rectangle {
                    x: Theme.dp(10)
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Theme.dp(6)
                    width: parent.width - Theme.dp(20)
                    height: Theme.dp(3)
                    radius: height / 2
                    color: Theme.fill
                    Rectangle {
                        height: parent.height
                        width: Math.max(height, parent.width * row.barFrac)
                        radius: height / 2
                        color: row.index === 0 ? Theme.accent : Theme.alpha(Theme.accent, row.index < 3 ? 0.72 : 0.45)
                        Behavior on width { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
                    }
                }
                MouseArea {
                    id: rowHit
                    anchors.fill: parent
                    anchors.rightMargin: rowActs.visible ? Theme.dp(66) : 0
                    hoverEnabled: true
                    cursorShape: row.modelData.dir ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: if (row.modelData.dir) root.analyze(row.modelData.path)
                }
                Row {
                    id: rowActs
                    visible: rowHover.hovered
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(6)
                    y: Theme.dp(6)
                    spacing: Theme.dp(2)
                    Act {
                        size: Theme.dp(26)
                        glyphSize: Theme.dp(15)
                        glyph: "open_in_new"
                        tip: row.modelData.dir ? I18n.tr("Open") : I18n.tr("Show in folder")
                        onClicked: {
                            if (row.modelData.dir) root.pane.folder.go(row.modelData.path)
                            else { root.pane.folder.focusPath = row.modelData.path; root.pane.folder.go(Fmt.parent(row.modelData.path)) }
                            root.close()
                        }
                    }
                    Act {
                        size: Theme.dp(26)
                        glyphSize: Theme.dp(15)
                        glyph: "delete"
                        tip: I18n.tr("Move to trash")
                        onClicked: {
                            const p = row.modelData.path
                            Core.job("trash", { paths: [p] }, { owner: root.pane.browser, say: I18n.n("%1 item moved to the trash", "%1 items moved to the trash", 1) })
                            Qt.callLater(() => root.analyze(root.path))
                        }
                    }
                }
            }
        }

        Txt {
            visible: !root.scanning && root.items.length === 0
            anchors.centerIn: parent
            text: root.error.length > 0 ? Errors.text(root.error) : I18n.tr("This folder is empty")
            size: Theme.small
            color: Theme.ink3
        }
    }

    actions: [
        Pill { text: I18n.tr("Done"); kind: "solid"; onClicked: root.close() }
    ]
}
