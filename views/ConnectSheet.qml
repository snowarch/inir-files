import QtQuick
import qs.services
import qs.kit

// Connect to a server: its address, then what the server asks (a name and a password, a question about its
// identity), then its folder opens. Servers opened before wait under the address. Given an address (a remote
// bookmark, a typed path), the sheet shows only when the server takes a moment or asks something.
Sheet {
    id: root
    required property var ops
    // Opened for one address (a bookmark, the path bar), not to type one.
    property bool direct: false
    property string address: ""
    property bool newTab: false
    property string step: "address"
    property string error: ""
    property var ask: ({})
    property var shares: []
    property string token: ""
    property var session: null
    property bool remember: false
    property int pick: -1
    readonly property var recent: Prefs.recall("servers", [])
    readonly property var fields: root.ask.fields ?? []
    readonly property string host: root.hostOf(root.address)
    cardWidth: Theme.dp(460)
    title: root.step === "busy" ? I18n.tr("Connecting to %1…", root.host)
        : root.step === "password" ? I18n.tr("Sign in to %1", root.host)
        : root.step === "question" ? root.host
        : root.step === "shares" ? I18n.tr("Shares on %1", root.host)
        : I18n.tr("Connect to server")
    subtitle: root.step === "address" ? I18n.tr("Type the address of a server: sftp, smb, ftp, WebDAV (dav, davs) or nfs.")
        : root.step === "shares" ? I18n.tr("Choose the share to open.")
        : root.step === "busy" ? "" : (root.ask.message ?? "")

    function hostOf(uri: string): string {
        const m = /^[a-z][a-z0-9+.-]*:\/\/(?:[^@/]*@)?(\[[^\]]*\]|[^:/]*)/i.exec(uri)
        if (!m || m[1].length === 0) return uri
        try { return decodeURIComponent(m[1]) } catch (e) { return m[1] }
    }
    function serverGlyph(uri: string): string { return /^(sftp|ssh):/i.test(uri) ? "dns" : "lan" }
    // What people paste: \\server\share from Windows, name@server:/folder from ssh, spaces as they are.
    function normalize(text: string): string {
        const t = text.trim()
        const encode = path => path.split("/").map(p => encodeURIComponent(p)).join("/")
        if (t.startsWith("\\\\")) {
            const parts = t.slice(2).split("\\").filter(p => p.length > 0)
            return parts.length === 0 ? "" : "smb://" + parts[0] + "/" + encode(parts.slice(1).join("/"))
        }
        const ssh = /^([^\s@/:]+@[^\s/:]+)(?::(\/.*))?$/.exec(t)
        if (ssh) return "sftp://" + ssh[1] + (ssh[2] ? encode(ssh[2]) : "/")
        const m = /^([a-z][a-z0-9+.-]*):\/\/(.*)$/i.exec(t)
        return m ? m[1].toLowerCase() + "://" + m[2].replace(/ /g, "%20") : t
    }
    function start(text: string): void {
        const uri = root.normalize(text)
        if (uri.length === 0) return
        if (!/^[a-z][a-z0-9+.-]*:\/\//.test(uri)) { root.error = Errors.text("badaddress"); return }
        root.address = uri
        root.error = ""
        root.step = "busy"
        root.token = "connect-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)
        const s = { live: true }
        root.session = s
        Core.call("connect", { uri: uri, token: root.token }, r => { if (s.live) root.finish(r) })
    }
    function finish(r: var): void {
        root.session = null
        if (r.ok && r.shares) { root.shares = r.shares; root.step = "shares"; root.reveal(); return }
        if (r.ok && r.path) {
            Prefs.remember("servers", [root.address].concat(root.recent.filter(u => u !== root.address)).slice(0, 8))
            if (r.remembered === false) Toast.fail(I18n.tr("The password could not be kept"))
            Core.refreshPlaces()
            const b = root.ops.browser
            if (root.newTab) b.newTab(r.path)
            else if (b.activePane) b.activePane.folder.go(r.path)
            root.close()
            return
        }
        // Turned down by the person: no error. A sheet that came for one address goes with it.
        if (r.error === "cancelled" && root.direct) { root.close(); return }
        root.error = r.error === "cancelled" ? "" : Errors.text(r.error)
        root.step = "address"
        root.reveal()
        Qt.callLater(() => addr.focusAll())
    }
    function next(f: var): void {
        const order = [userField, domainField, passField].filter(x => x.visible)
        const i = order.indexOf(f)
        if (i >= 0 && i < order.length - 1) order[i + 1].focusAll()
        else root.send()
    }
    function send(): void {
        if (root.step !== "password" || (root.fields.includes("password") && passField.text.length === 0)) return
        Core.call("connect_answer", { token: root.token, user: userField.text, domain: domainField.text, password: passField.text,
            remember: root.remember && root.ask.keyring === true })
        passField.text = ""
        root.step = "busy"
    }
    function choose(i: int): void {
        if (root.step !== "question") return
        Core.call("connect_answer", { token: root.token, choice: i })
        root.step = "busy"
    }
    function forget(uri: string): void { Prefs.remember("servers", root.recent.filter(u => u !== uri)) }
    // Up and Down in the address walk through the servers opened before.
    function cycle(step: int): void {
        if (root.recent.length === 0) return
        root.pick = Math.max(0, Math.min(root.recent.length - 1, root.pick + step))
        addr.text = root.recent[root.pick]
        addr.input.cursorPosition = addr.text.length
    }

    onDismissed: if (root.session) { root.session.live = false; Core.call("connect_answer", { token: root.token, cancel: true }) }
    Component.onCompleted: {
        root.direct = root.address.length > 0
        if (root.direct) root.start(root.address)
        else Qt.callLater(() => addr.focusAll())
    }
    Connections {
        target: Core
        function onAsked(m) {
            if (m.token !== root.token) return
            root.ask = m
            if (m.kind === "question") {
                root.step = "question"
                root.forceActiveFocus()
            } else {
                userField.text = m.user ?? ""
                domainField.text = m.domain ?? ""
                passField.text = ""
                root.step = "password"
                Qt.callLater(() => (userField.visible && userField.text.length === 0 ? userField : passField).focusAll())
            }
            root.reveal()
        }
    }

    component Choice: Rectangle {
        id: row
        property string label: ""
        property string glyph: ""
        property bool removable: false
        signal chosen()
        signal removed()
        width: parent ? parent.width : 0
        height: Theme.dp(38)
        radius: Theme.round(10)
        color: rowMouse.pressed ? Theme.fillPress : rowMouse.containsMouse ? Theme.fill : "transparent"
        Glyph { id: rowGlyph; x: Theme.dp(10); anchors.verticalCenter: parent.verticalCenter; name: row.glyph; size: Theme.dp(19); color: Theme.ink2 }
        Txt {
            anchors.left: rowGlyph.right
            anchors.leftMargin: Theme.dp(10)
            anchors.right: forgetAct.visible ? forgetAct.left : parent.right
            anchors.rightMargin: Theme.dp(8)
            anchors.verticalCenter: parent.verticalCenter
            text: row.label
            elide: Text.ElideMiddle
        }
        MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: row.chosen() }
        Act {
            id: forgetAct
            visible: row.removable
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(7)
            anchors.verticalCenter: parent.verticalCenter
            size: Theme.dp(24)
            glyphSize: Theme.dp(16)
            glyph: "close"
            tip: I18n.tr("Forget")
            onClicked: row.removed()
        }
    }

    // ---- the address
    Field {
        id: addr
        width: parent.width
        visible: root.step === "address"
        glyph: "dns"
        placeholder: I18n.tr("For example sftp://name@server or smb://server/share")
        text: root.address
        onAccepted: root.start(addr.text)
        onEscaped: root.close()
        onEdited: { root.error = ""; root.pick = -1 }
        Keys.onDownPressed: root.cycle(1)
        Keys.onUpPressed: root.cycle(-1)
    }
    Txt {
        visible: root.step === "address" && root.error.length > 0
        width: parent.width
        text: root.error
        color: Theme.danger
        wrapMode: Text.Wrap
        elide: Text.ElideNone
    }
    Column {
        visible: root.step === "address" && root.recent.length > 0
        width: parent.width
        spacing: Theme.dp(2)
        Caption { text: I18n.tr("Recent servers"); bottomPadding: Theme.dp(4) }
        Repeater {
            model: root.recent
            delegate: Choice {
                required property var modelData
                label: modelData
                glyph: root.serverGlyph(modelData)
                removable: true
                onChosen: root.start(modelData)
                onRemoved: root.forget(modelData)
            }
        }
    }

    // ---- on its way
    Item {
        visible: root.step === "busy"
        width: parent.width
        height: Theme.dp(24)
        Ring { id: ring; anchors.verticalCenter: parent.verticalCenter }
        Txt {
            anchors.left: ring.right
            anchors.leftMargin: Theme.dp(10)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.address
            color: Theme.ink2
            elide: Text.ElideMiddle
        }
    }

    // ---- what the server asks
    Txt {
        visible: root.step === "password" && root.ask.again === true
        width: parent.width
        text: I18n.tr("The server did not take that. Check the name and the password.")
        color: Theme.danger
        wrapMode: Text.Wrap
        elide: Text.ElideNone
    }
    Field {
        id: userField
        width: parent.width
        visible: root.step === "password" && root.fields.includes("user")
        glyph: "person"
        placeholder: I18n.tr("Name")
        onAccepted: root.next(userField)
        onEscaped: root.close()
    }
    Field {
        id: domainField
        width: parent.width
        visible: root.step === "password" && root.fields.includes("domain")
        glyph: "domain"
        placeholder: I18n.tr("Domain")
        onAccepted: root.next(domainField)
        onEscaped: root.close()
    }
    Field {
        id: passField
        width: parent.width
        visible: root.step === "password" && root.fields.includes("password")
        glyph: "key"
        placeholder: I18n.tr("Password")
        clearable: false
        onAccepted: root.send()
        onEscaped: root.close()
        Component.onCompleted: input.echoMode = TextInput.Password
    }
    Check {
        visible: root.step === "password" && root.ask.keyring === true
        text: I18n.tr("Remember the password")
        checked: root.remember
        onToggled: v => root.remember = v
    }

    // ---- the shares of a server
    Column {
        visible: root.step === "shares"
        width: parent.width
        spacing: Theme.dp(2)
        Repeater {
            model: root.shares
            delegate: Choice {
                required property var modelData
                label: modelData.name
                glyph: "folder_shared"
                onChosen: root.start(modelData.uri)
            }
        }
    }

    actions: [
        Pill { visible: root.step !== "question"; text: I18n.tr("Cancel"); kind: "plain"; onClicked: root.close() },
        // The server's own choices, its first one last, where the main button sits.
        Repeater {
            model: root.step === "question" ? (root.ask.choices ?? []).map((t, i) => ({ text: t, at: i })).reverse() : []
            delegate: Pill {
                required property var modelData
                text: modelData.text
                kind: modelData.at === 0 ? "solid" : "quiet"
                onClicked: root.choose(modelData.at)
            }
        },
        Pill { visible: root.step === "address"; text: I18n.tr("Connect"); kind: "solid"; enabled: addr.text.trim().length > 0; onClicked: root.start(addr.text) },
        Pill { visible: root.step === "password"; text: I18n.tr("Connect"); kind: "solid"; enabled: passField.text.length > 0 || !passField.visible; onClicked: root.send() }
    ]
}
