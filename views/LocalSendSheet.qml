import QtQuick
import QtQuick.Controls.Basic as QQC
import qs.services
import qs.kit

// LocalSend v2.1 nearby sharing sheet: lists auto-discovered LAN devices, scans the subnet on demand,
// connects manually by IP, sends selected files/folders, and tracks active transfers.
Sheet {
    id: root
    required property var browser
    property var paths: []
    property bool probing: false
    cardWidth: Theme.dp(540)
    title: I18n.tr("LocalSend")
    subtitle: Core.localSendRunning
        ? I18n.tr("%1 · Port %2", Core.localSendAlias || I18n.tr("This computer"), Core.localSendPort)
        : I18n.tr("Nearby sharing is off")

    function deviceGlyph(kind: string): string {
        if (kind === "mobile") return "smartphone"
        if (kind === "web") return "language"
        if (kind === "server" || kind === "headless") return "dns"
        return "computer"
    }
    readonly property var transferList: {
        const map = Core.localSendTransfers ?? {}
        return Object.keys(map).map(k => map[k]).reverse()
    }
    function sendTo(peer: var): void {
        if (!peer || root.paths.length === 0) return
        root.browser.actions.sendLocalSend(peer, root.paths, "")
        root.paths = []
    }
    function probeIp(): void {
        const raw = ipField.text.trim()
        if (raw.length === 0 || root.probing) return
        let host = raw, port = 53317
        const idx = raw.lastIndexOf(":")
        if (idx > 0 && raw.indexOf(":") === idx) {
            const p = Number(raw.slice(idx + 1))
            if (p > 0 && p <= 65535) { host = raw.slice(0, idx); port = p }
        }
        root.probing = true
        Core.call("localsend_probe", { host: host, port: port }, r => {
            if (!root) return
            root.probing = false
            if (!r.ok) { Toast.fail(Errors.text(r.error)); return }
            ipField.text = ""
            Toast.show(I18n.tr("Device found"), "", null)
        })
    }

    Component.onCompleted: {
        if (!Core.localSendRunning) {
            Prefs.set("localsend", true)
            Core.syncLocalSend()
        }
        Core.scanLocalSend()
    }

    // ---- selected payload banner (shown when sending files)
    Rectangle {
        visible: root.paths.length > 0
        width: parent.width
        height: Theme.dp(46)
        radius: Theme.radius
        color: Theme.accentPlate
        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.dp(14)
            anchors.right: clearSend.left
            anchors.rightMargin: Theme.dp(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(10)
            Glyph { anchors.verticalCenter: parent.verticalCenter; name: "upload_file"; fill: 1; size: Theme.dp(18); color: Theme.accentInk }
            Txt {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(Theme.dp(40), parent.width - Theme.dp(28))
                text: root.paths.length === 1
                    ? I18n.tr("Ready to send “%1”", Fmt.name(root.paths[0]))
                    : I18n.n("Ready to send %1 item", "Ready to send %1 items", root.paths.length)
                size: Theme.row
                strong: true
                color: Theme.accentInk
                elide: Text.ElideMiddle
            }
        }
        Act {
            id: clearSend
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(8)
            anchors.verticalCenter: parent.verticalCenter
            size: Theme.dp(28)
            glyphSize: Theme.dp(16)
            glyph: "close"
            tip: I18n.tr("Clear selection")
            onClicked: root.paths = []
        }
    }

    // ---- nearby devices header + scan button
    Item {
        width: parent.width
        height: Theme.dp(30)
        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(8)
            Caption { anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("Nearby devices") }
            Ring {
                visible: Core.localSendScanning
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.dp(14)
                height: width
                value: -1
            }
        }
        Pill {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            glyph: "radar"
            text: Core.localSendScanning ? I18n.tr("Scanning…") : I18n.tr("Scan network")
            enabled: !Core.localSendScanning
            onClicked: Core.scanLocalSend()
        }
    }

    // ---- peer list
    Item {
        width: parent.width
        height: Math.min(Theme.dp(240), Math.max(Core.localSendPeers.length === 0 ? Theme.dp(92) : Theme.dp(56), peerCol.implicitHeight))
        Flickable {
            anchors.fill: parent
            contentHeight: peerCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollBar.vertical: Scroller {}
            Column {
                id: peerCol
                width: parent.width
                spacing: Theme.dp(6)

                // Empty state
                Item {
                    visible: Core.localSendPeers.length === 0
                    width: parent.width
                    height: Theme.dp(92)
                    Column {
                        anchors.centerIn: parent
                        width: parent.width - Theme.dp(24)
                        spacing: Theme.dp(4)
                        Txt {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            text: Core.localSendScanning ? I18n.tr("Looking for LocalSend devices…") : I18n.tr("No LocalSend devices found nearby")
                            size: Theme.row
                            strong: true
                            color: Theme.ink2
                        }
                        Txt {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            text: I18n.tr("Open LocalSend on another device on the same network, or enter its IP below.")
                            size: Theme.small
                            color: Theme.ink3
                        }
                    }
                }

                Repeater {
                    model: Core.localSendPeers
                    delegate: Rectangle {
                        id: peerCard
                        required property var modelData
                        width: peerCol.width
                        height: Theme.dp(56)
                        radius: Theme.radius
                        color: peerHit.pressed ? Theme.cardPress : peerHover.hovered ? Theme.cardHover : Theme.card
                        Behavior on color { ColorAnimation { duration: Theme.hoverMs } }
                        HoverHandler { id: peerHover }

                        Rectangle {
                            id: badge
                            x: Theme.dp(12)
                            anchors.verticalCenter: parent.verticalCenter
                            width: Theme.dp(34)
                            height: width
                            radius: Theme.round(10)
                            color: Theme.accentPlate
                            Glyph {
                                anchors.centerIn: parent
                                name: root.deviceGlyph(peerCard.modelData.deviceType ?? "")
                                fill: 1
                                size: Theme.dp(18)
                                color: Theme.accentInk
                            }
                        }
                        Column {
                            anchors.left: badge.right
                            anchors.leftMargin: Theme.dp(12)
                            anchors.right: sendBtn.visible ? sendBtn.left : parent.right
                            anchors.rightMargin: Theme.dp(12)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.dp(2)
                            Txt {
                                width: parent.width
                                text: peerCard.modelData.alias || peerCard.modelData.ip
                                size: Theme.row
                                strong: true
                                color: Theme.ink
                            }
                            Txt {
                                width: parent.width
                                text: [peerCard.modelData.deviceModel, peerCard.modelData.ip + ":" + peerCard.modelData.port].filter(s => s && s.length > 0).join(" · ")
                                size: Theme.small
                                color: Theme.ink3
                            }
                        }
                        MouseArea {
                            id: peerHit
                            anchors.fill: parent
                            anchors.rightMargin: sendBtn.visible ? sendBtn.width + Theme.dp(16) : 0
                            hoverEnabled: true
                            cursorShape: root.paths.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: if (root.paths.length > 0) root.sendTo(peerCard.modelData)
                        }
                        Pill {
                            id: sendBtn
                            visible: root.paths.length > 0
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.dp(10)
                            anchors.verticalCenter: parent.verticalCenter
                            compact: true
                            kind: "solid"
                            glyph: "send"
                            text: I18n.tr("Send")
                            onClicked: root.sendTo(peerCard.modelData)
                        }
                    }
                }
            }
        }
    }

    // ---- active / recent transfers
    Column {
        visible: root.transferList.length > 0
        width: parent.width
        spacing: Theme.dp(6)
        Caption { text: I18n.tr("Transfers") }
        Repeater {
            model: root.transferList.slice(0, 4)
            delegate: Rectangle {
                id: tCard
                required property var modelData
                readonly property var t: tCard.modelData
                readonly property bool busy: t.state === "waiting" || t.state === "sending" || t.state === "receiving"
                readonly property real frac: (t.totalBytes ?? 0) > 0 ? Math.min(1, (t.bytes ?? 0) / t.totalBytes) : (t.state === "done" ? 1 : 0)
                width: parent.width
                height: Theme.dp(54)
                radius: Theme.radius
                color: Theme.card

                Glyph {
                    id: tGlyph
                    x: Theme.dp(12)
                    anchors.verticalCenter: parent.verticalCenter
                    name: t.direction === "receive" ? "download" : "upload"
                    size: Theme.dp(18)
                    color: t.state === "done" ? Theme.success : t.state === "failed" || t.state === "rejected" ? Theme.danger : Theme.accentInk
                }
                Column {
                    anchors.left: tGlyph.right
                    anchors.leftMargin: Theme.dp(10)
                    anchors.right: tAct.left
                    anchors.rightMargin: Theme.dp(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.dp(4)
                    Txt {
                        width: parent.width
                        size: Theme.small
                        strong: true
                        color: Theme.ink
                        text: {
                            const dir = t.direction === "receive" ? I18n.tr("From %1", t.peer ?? "") : I18n.tr("To %1", t.peer ?? "")
                            if (t.state === "waiting") return dir + " · " + I18n.tr("Waiting for acceptance…")
                            if (t.state === "done") return dir + " · " + I18n.tr("Completed")
                            if (t.state === "rejected") return dir + " · " + I18n.tr("Declined")
                            if (t.state === "cancelled") return dir + " · " + I18n.tr("Cancelled")
                            if (t.state === "failed") return dir + " · " + I18n.tr("Failed")
                            return dir + (t.current ? " · " + t.current : "")
                        }
                    }
                    Meter {
                        visible: tCard.busy
                        width: parent.width
                        height: Theme.dp(3)
                        value: tCard.frac
                    }
                }
                Row {
                    id: tAct
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.dp(4)
                    Act {
                        visible: tCard.t.direction === "receive" && tCard.t.state === "done" && (tCard.t.dest ?? "").length > 0
                        size: Theme.dp(26)
                        glyphSize: Theme.dp(15)
                        glyph: "folder_open"
                        tip: I18n.tr("Open folder")
                        onClicked: {
                            if (root.browser.activePane) root.browser.activePane.folder.go(tCard.t.dest)
                            root.close()
                        }
                    }
                    Act {
                        size: Theme.dp(26)
                        glyphSize: Theme.dp(15)
                        glyph: "close"
                        tip: tCard.busy ? I18n.tr("Cancel") : I18n.tr("Dismiss")
                        onClicked: {
                            if (tCard.busy) Core.call("localsend_cancel", { id: tCard.t.id })
                            else Core.forgetLocalSendTransfer(tCard.t.id)
                        }
                    }
                }
            }
        }
    }

    // ---- manual IP probe (for networks blocking multicast)
    Row {
        width: parent.width
        spacing: Theme.dp(8)
        Field {
            id: ipField
            width: parent.width - probeBtn.width - Theme.dp(8)
            glyph: "lan"
            placeholder: I18n.tr("Connect by IP (e.g. 192.168.1.42)")
            onAccepted: root.probeIp()
        }
        Pill {
            id: probeBtn
            anchors.verticalCenter: parent.verticalCenter
            text: root.probing ? I18n.tr("Finding…") : I18n.tr("Find")
            enabled: !root.probing && ipField.text.trim().length > 0
            onClicked: root.probeIp()
        }
    }

    // ---- receive preferences footer
    Item {
        width: parent.width
        height: Theme.dp(34)
        readonly property string curDir: root.browser.activePane && root.browser.activePane.folder.mode === "folder" && root.browser.activePane.folder.writable ? root.browser.activePane.folder.path : ""
        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(6)
            Txt {
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.tr("Save to: %1", Fmt.pretty(Core.localSendSaveDir || Core.home))
                size: Theme.small
                color: Theme.ink3
                elide: Text.ElideMiddle
                width: Math.min(implicitWidth, Theme.dp(200))
            }
            Act {
                visible: parent.parent.curDir.length > 0 && parent.parent.curDir !== Core.localSendSaveDir
                anchors.verticalCenter: parent.verticalCenter
                size: Theme.dp(24)
                glyphSize: Theme.dp(15)
                glyph: "folder"
                tip: I18n.tr("Save in current folder")
                onClicked: Core.call("localsend_config", { saveDir: parent.parent.curDir }, r => { if (r.ok) Core.applyLocalSendStatus(r) })
            }
        }
        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(8)
            Txt { anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("Auto-accept"); size: Theme.small; color: Theme.ink2 }
            Toggle {
                checked: Prefs.localsendAutoAccept === true
                onToggled: v => Prefs.set("localsendAutoAccept", v)
            }
        }
    }

    actions: [
        Pill {
            visible: Core.localSendRunning
            text: I18n.tr("Turn off")
            kind: "plain"
            onClicked: { Prefs.set("localsend", false); root.close() }
        },
        Pill { text: I18n.tr("Done"); kind: "solid"; onClicked: root.close() }
    ]
}
