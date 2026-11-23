import QtQuick
import Quickshell
import qs.services
import qs.kit

// All there is to know about a file, and what can be set: who may read and change it, the app that opens its kind,
// its checksum. Several files show what they add up to.
Sheet {
    id: root
    required property var browser
    property var paths: []
    readonly property bool one: root.paths.length === 1
    property var info: ({})
    property var entries: []
    property string tab: "general"
    property var sizing: null
    property string sizeToken: ""
    property var apps: []
    property string usual: ""
    property string algo: "sha256"
    property var sum: null
    property string sumToken: ""
    cardWidth: Theme.dp(500)

    function load(): void {
        if (root.one) Core.call("info", { path: root.paths[0] }, r => { if (r.ok) root.info = r })
        Core.call("stat", { paths: root.paths }, r => {
            if (!r.ok) return
            root.entries = r.entries
            if (r.entries.some(e => e.dir)) {
                root.sizeToken = "props-" + Date.now()
                Core.call("dirsize", { token: root.sizeToken, paths: root.paths })
            }
            if (root.one && !r.entries[0].dir) Core.call("apps", { mime: r.entries[0].mime }, a => { if (a.ok) { root.apps = a.apps; root.usual = a.default ?? "" } })
        })
    }
    Component.onCompleted: root.load()
    Component.onDestruction: {
        if (root.sizeToken.length > 0) Core.call("cancel", { token: root.sizeToken })
        if (root.sumToken.length > 0) Core.call("cancel", { token: root.sumToken })
    }
    Connections {
        target: Core
        function onSizeEvent(d) { if (d.token === root.sizeToken) root.sizing = d }
        function onChecksumEvent(d) { if (d.token === root.sumToken) root.sum = d }
    }
    function checksum(algo: string): void {
        if (root.sumToken.length > 0) Core.call("cancel", { token: root.sumToken })
        root.algo = algo
        root.sum = { progress: 0 }
        root.sumToken = "sum-" + Date.now()
        Core.call("checksum", { token: root.sumToken, path: root.paths[0], algo: algo })
    }
    function chmod(bit: int): void {
        Core.call("chmod", { path: root.paths[0], mode: root.info.mode ^ bit }, r => {
            if (!r.ok) { Toast.fail(Errors.text(r.error)); return }
            Core.call("info", { path: root.paths[0] }, i => { if (i.ok) root.info = i })
        })
    }

    readonly property var first: root.entries[0] ?? null
    readonly property bool isDir: root.one && !!root.first && root.first.dir
    readonly property real total: root.sizing ? root.sizing.size : root.entries.reduce((s, e) => s + (e.dir ? 0 : e.size), 0)
    readonly property var tabs: {
        const t = [{ value: "general", text: I18n.tr("General") }]
        if (root.one) t.push({ value: "access", text: I18n.tr("Access") })
        if (root.one && !root.isDir) t.push({ value: "apps", text: I18n.tr("Opens with") })
        if (root.one && !root.isDir) t.push({ value: "sum", text: I18n.tr("Checksum") })
        return t
    }
    readonly property var facts: {
        const out = []
        const add = (key, value, run) => { if (value !== undefined && value !== null && String(value).length > 0) out.push({ key: key, value: String(value), run: run ?? null }) }
        const i = root.info
        if (root.one) add(I18n.tr("Kind"), i.comment)
        else {
            const counts = {}
            for (const e of root.entries) counts[e.comment || e.kind] = (counts[e.comment || e.kind] ?? 0) + 1
            add(I18n.tr("Kinds"), Object.keys(counts).map(k => counts[k] + " × " + k).join(", "))
        }
        const sizeLine = Fmt.size(root.total) + (root.total >= 1000 ? " (" + I18n.n("%1 byte", "%1 bytes", root.total) + ")" : "")
        add(I18n.tr("Size"), root.sizing && !root.sizing.done ? sizeLine + "…" : sizeLine)
        if (root.sizing) add(I18n.tr("Contains"), I18n.n("%1 file", "%1 files", root.sizing.files) + ", " + I18n.n("%1 folder", "%1 folders", root.sizing.dirs))
        const parent = root.one ? i.parent : (root.paths.every(p => Fmt.parent(p) === Fmt.parent(root.paths[0])) ? Fmt.parent(root.paths[0]) : "")
        if (parent) add(I18n.tr("Folder"), Fmt.pretty(parent), () => { root.close(); root.browser.activePane.folder.go(parent); if (root.one) root.browser.activePane.folder.focusPath = root.paths[0] })
        if (i.target) add(I18n.tr("Points to"), i.target)
        if (root.one) {
            add(I18n.tr("Modified"), Fmt.full(i.mtime))
            if (i.btime > 0) add(I18n.tr("Created"), Fmt.full(i.btime))
            add(I18n.tr("Opened"), Fmt.full(i.atime))
            if (i.width > 0) add(I18n.tr("Dimensions"), i.width + " × " + i.height)
            if (i.media && i.media.duration > 0) add(I18n.tr("Length"), Fmt.duration(i.media.duration))
            if (i.pdf && i.pdf.pages > 0) add(I18n.tr("Pages"), i.pdf.pages)
        }
        return out
    }

    // ---- head: the file itself
    Row {
        width: parent.width
        spacing: Theme.dp(14)
        FileIcon { id: icon; size: Theme.dp(56); entry: root.first }
        Column {
            width: parent.width - icon.width - Theme.dp(14)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(2)
            Txt {
                width: parent.width
                text: root.one ? (root.first ? root.first.name || "/" : "") : Fmt.items(root.paths.length)
                font.family: Theme.title
                size: Theme.head
                strong: true
                wrapMode: Text.WrapAnywhere
                maximumLineCount: 2
            }
            Txt { width: parent.width; text: root.one ? (root.info.comment ?? "") : Fmt.size(root.total); color: Theme.ink2; size: Theme.small }
        }
    }
    Segments {
        visible: root.tabs.length > 1
        options: root.tabs
        value: root.tab
        onChosen: value => root.tab = value
    }

    // ---- general
    Column {
        visible: root.tab === "general"
        width: parent.width
        spacing: Theme.dp(2)
        Repeater {
            model: root.facts
            Item {
                required property var modelData
                width: parent.width
                height: Math.max(Theme.dp(26), value.implicitHeight + Theme.dp(6))
                Txt { width: parent.width * 0.3; height: Theme.dp(26); text: parent.modelData.key; color: Theme.ink3; size: Theme.small }
                Txt {
                    id: value
                    x: parent.width * 0.3 + Theme.dp(8)
                    y: Theme.dp(5)
                    width: parent.width - x
                    text: parent.modelData.value
                    size: Theme.small
                    color: parent.modelData.run ? Theme.accentInk : Theme.ink
                    wrapMode: Text.WrapAnywhere
                    elide: Text.ElideNone
                    verticalAlignment: Text.AlignTop
                    font.underline: !!parent.modelData.run && linkMouse.containsMouse
                    MouseArea { id: linkMouse; anchors.fill: parent; enabled: !!parent.parent.modelData.run; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.parent.modelData.run() }
                }
            }
        }
        Column {
            visible: root.isDir && !!root.info.space && root.info.space.total > 0
            width: parent.width
            topPadding: Theme.dp(8)
            spacing: Theme.dp(6)
            Meter { width: parent.width; value: root.info.space ? 1 - root.info.space.free / Math.max(1, root.info.space.total) : 0 }
            Txt { text: root.info.space ? I18n.tr("%1 free of %2", Fmt.size(root.info.space.free), Fmt.size(root.info.space.total)) : ""; color: Theme.ink2; size: Theme.small }
        }
    }

    // ---- access
    Column {
        visible: root.tab === "access"
        width: parent.width
        spacing: Theme.dp(10)
        Txt { text: I18n.tr("Owner: %1 · Group: %2", root.info.owner ?? "", root.info.group ?? ""); color: Theme.ink2; size: Theme.small }
        Row {
            spacing: Theme.dp(18)
            Item { width: Theme.dp(70); height: 1 }
            Repeater {
                model: [I18n.tr("Read"), I18n.tr("Change"), root.isDir ? I18n.tr("Enter") : I18n.tr("Run")]
                Caption { required property string modelData; width: Theme.dp(96); text: modelData }
            }
        }
        Column {
            spacing: Theme.dp(6)
            Repeater {
                model: [I18n.tr("Owner"), I18n.tr("Group"), I18n.tr("Others")]
                Row {
                    id: permRow
                    required property string modelData
                    required property int index
                    spacing: Theme.dp(18)
                    Txt { width: Theme.dp(70); height: Theme.dp(26); text: permRow.modelData; size: Theme.small }
                    Repeater {
                        model: 3
                        Check {
                            required property int index
                            readonly property int bit: (4 >> index) << (3 * (2 - permRow.index))
                            width: Theme.dp(96)
                            checked: ((root.info.mode ?? 0) & bit) !== 0
                            onToggled: root.chmod(bit)
                        }
                    }
                }
            }
        }
        Txt { text: root.info.modeText ? root.info.modeText + "  ·  " + ((root.info.mode ?? 0).toString(8).padStart(4, "0")) : ""; color: Theme.ink3; size: Theme.small; font.family: Theme.mono }
    }

    // ---- the app that opens it
    Column {
        visible: root.tab === "apps"
        width: parent.width
        spacing: Theme.dp(2)
        Txt { width: parent.width; text: I18n.tr("Every %1 opens with the app chosen here.", root.info.comment ?? ""); color: Theme.ink2; size: Theme.small; wrapMode: Text.Wrap; elide: Text.ElideNone; bottomPadding: Theme.dp(6) }
        Repeater {
            model: root.apps
            Item {
                id: appRow
                required property var modelData
                readonly property bool on: root.usual === modelData.id
                readonly property string iconUrl: modelData.icon ? (modelData.icon.startsWith("/") ? Fmt.url(modelData.icon) : Quickshell.iconPath(modelData.icon, true)) : ""
                width: parent.width
                height: Theme.dp(40)
                Rectangle { anchors.fill: parent; radius: Theme.radius; color: appRow.on ? Theme.accentPlate : appMouse.containsMouse ? Theme.fill : "transparent" }
                Image { id: appIcon; x: Theme.dp(10); anchors.verticalCenter: parent.verticalCenter; width: Theme.dp(24); height: width; sourceSize: Qt.size(width * 2, height * 2); source: appRow.iconUrl; visible: status === Image.Ready }
                Glyph { anchors.centerIn: appIcon; visible: !appIcon.visible; name: "apps"; size: Theme.dp(20); color: Theme.ink3 }
                Txt { anchors.left: appIcon.right; anchors.leftMargin: Theme.dp(10); anchors.verticalCenter: parent.verticalCenter; text: appRow.modelData.name; strong: appRow.on; color: appRow.on ? Theme.accentInk : Theme.ink }
                Glyph { visible: appRow.on; anchors.right: parent.right; anchors.rightMargin: Theme.dp(12); anchors.verticalCenter: parent.verticalCenter; name: "check"; size: Theme.dp(18); color: Theme.accentInk }
                MouseArea {
                    id: appMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: Core.call("set_default", { mime: root.first.mime, app: appRow.modelData.id }, r => { if (r.ok) root.usual = appRow.modelData.id; else Toast.fail(Errors.text(r.error)) })
                }
            }
        }
    }

    // ---- checksum
    Column {
        visible: root.tab === "sum"
        width: parent.width
        spacing: Theme.dp(10)
        Row {
            spacing: Theme.dp(8)
            Segments {
                options: [{ value: "md5", text: "MD5" }, { value: "sha256", text: "SHA-256" }, { value: "sha512", text: "SHA-512" }]
                value: root.algo
                onChosen: value => root.checksum(value)
            }
            Pill { compact: true; text: I18n.tr("Work it out"); visible: !root.sum; onClicked: root.checksum(root.algo); anchors.verticalCenter: parent.verticalCenter }
        }
        Meter { visible: !!root.sum && !root.sum.value && !root.sum.error; width: parent.width; value: root.sum ? root.sum.progress ?? 0 : 0 }
        Inset {
            visible: !!root.sum && !!root.sum.value
            width: parent.width
            height: sumText.implicitHeight + Theme.dp(18)
            radius: Theme.radius
            TextEdit {
                id: sumText
                x: Theme.dp(12)
                y: Theme.dp(9)
                width: parent.width - Theme.dp(52)
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.WrapAnywhere
                text: root.sum ? root.sum.value ?? "" : ""
                color: Theme.ink
                font.family: Theme.mono
                font.pixelSize: Theme.small
            }
            Act { anchors.right: parent.right; anchors.rightMargin: Theme.dp(4); anchors.verticalCenter: parent.verticalCenter; size: Theme.dp(30); glyphSize: Theme.dp(16); glyph: "content_copy"; tip: I18n.tr("Copy"); onClicked: root.browser.actions.copyText(sumText.text) }
        }
        Txt { visible: !!root.sum && !!root.sum.error; text: root.sum && root.sum.error ? Errors.text(root.sum.error) : ""; color: Theme.danger; size: Theme.small }
        Row {
            visible: !!root.sum && !!root.sum.value
            width: parent.width
            spacing: Theme.dp(8)
            readonly property string want: compare.text.trim().toLowerCase()
            Field { id: compare; width: parent.width - Theme.dp(34); placeholder: I18n.tr("Paste a checksum to compare") }
            Glyph {
                anchors.verticalCenter: parent.verticalCenter
                visible: parent.want.length > 0
                name: parent.want === (root.sum?.value ?? "") ? "check_circle" : "cancel"
                fill: 1
                size: Theme.dp(22)
                color: parent.want === (root.sum?.value ?? "") ? Theme.success : Theme.danger
            }
        }
    }

    actions: [
        Pill { text: I18n.tr("Close"); kind: "solid"; onClicked: root.close() }
    ]
}
