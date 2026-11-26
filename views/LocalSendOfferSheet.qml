import QtQuick
import qs.services
import qs.kit

// Incoming LocalSend transfer offer: shows sender, file list, destination folder, and Accept / Decline.
Sheet {
    id: root
    required property var browser
    required property var offer
    property bool answered: false
    property string destDir: root.offer?.saveDir || Core.localSendSaveDir || Core.home
    cardWidth: Theme.dp(460)
    title: I18n.tr("Incoming files via LocalSend")
    subtitle: {
        const s = root.offer?.sender
        const who = s ? (s.alias || s.ip) : ""
        const detail = s && s.deviceModel ? s.deviceModel + " · " + s.ip : (s?.ip ?? "")
        return detail.length > 0 ? who + " (" + detail + ")" : who
    }

    function accept(): void {
        if (root.answered) return
        root.answered = true
        Core.call("localsend_accept", { sessionId: root.offer.sessionId, dest: root.destDir })
        root.close()
    }
    function decline(): void {
        if (root.answered) return
        root.answered = true
        Core.call("localsend_decline", { sessionId: root.offer.sessionId })
        root.close()
    }
    Component.onDestruction: if (!root.answered && root.offer?.sessionId) Core.call("localsend_decline", { sessionId: root.offer.sessionId })

    readonly property var files: root.offer?.files ?? []
    readonly property string hereDir: root.browser.activePane && root.browser.activePane.folder.mode === "folder" && root.browser.activePane.folder.writable ? root.browser.activePane.folder.path : ""

    Column {
        width: parent.width
        spacing: Theme.dp(4)
        Repeater {
            model: root.files.slice(0, 6)
            delegate: Rectangle {
                required property var modelData
                width: parent.width
                height: Theme.dp(34)
                radius: Theme.round(8)
                color: Theme.card
                Glyph { id: fg; x: Theme.dp(10); anchors.verticalCenter: parent.verticalCenter; name: "draft"; size: Theme.dp(16); color: Theme.ink2 }
                Txt {
                    anchors.left: fg.right
                    anchors.leftMargin: Theme.dp(8)
                    anchors.right: fsz.left
                    anchors.rightMargin: Theme.dp(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.fileName ?? ""
                    size: Theme.small
                    color: Theme.ink
                    elide: Text.ElideMiddle
                }
                Txt {
                    id: fsz
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(10)
                    anchors.verticalCenter: parent.verticalCenter
                    text: Fmt.size(modelData.size ?? 0)
                    size: Theme.caption
                    color: Theme.ink3
                }
            }
        }
        Txt {
            visible: root.files.length > 6
            text: I18n.n("+ %1 more file", "+ %1 more files", root.files.length - 6)
            size: Theme.small
            color: Theme.ink3
            leftPadding: Theme.dp(4)
        }
    }

    Item {
        width: parent.width
        height: Theme.dp(28)
        Txt {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: I18n.n("%1 file", "%1 files", root.files.length) + " · " + Fmt.size(root.offer?.totalBytes ?? 0)
            size: Theme.small
            strong: true
            color: Theme.ink2
        }
        Pill {
            visible: root.hereDir.length > 0 && root.hereDir !== root.destDir
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            glyph: "folder"
            text: I18n.tr("Save in current folder")
            onClicked: root.destDir = root.hereDir
        }
    }

    Txt {
        width: parent.width
        text: I18n.tr("Save to: %1", Fmt.pretty(root.destDir))
        size: Theme.small
        color: Theme.ink3
        elide: Text.ElideMiddle
    }

    actions: [
        Pill { text: I18n.tr("Decline"); kind: "plain"; onClicked: root.decline() },
        Pill { text: I18n.tr("Accept"); kind: "solid"; glyph: "download"; onClicked: root.accept() }
    ]
}
