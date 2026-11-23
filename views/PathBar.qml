import QtQuick
import QtQuick.Controls.Basic as QQC
import qs.services
import qs.kit

// Where the pane is, as steps to click. Each step takes drops and opens when a drag rests on it. A click on the empty
// end, or Ctrl+L, turns the steps into a line to type a path into; Tab completes a folder name.
Inset {
    id: root
    required property var browser
    readonly property var pane: root.browser.activePane
    readonly property var folder: root.pane ? root.pane.folder : null
    property bool editing: false
    radius: Theme.dp(12)
    implicitHeight: Theme.dp(36)
    focused: root.editing

    readonly property var crumbs: {
        const f = root.folder
        if (!f) return []
        if (f.mode === "trash") return [{ path: "trash:", name: I18n.tr("Trash"), glyph: "delete" }]
        if (f.mode === "recent") return [{ path: "recent:", name: I18n.tr("Recent"), glyph: "schedule" }]
        const base = f.mode === "search" ? f.searchRoot : f.path
        const home = Core.home
        let out, rest
        if (base === home || base.startsWith(home + "/")) {
            out = [{ path: home, name: I18n.tr("Home"), glyph: "home" }]
            rest = base.slice(home.length)
        } else {
            out = [{ path: "/", name: Core.places.host || I18n.tr("Computer"), glyph: "hard_drive" }]
            rest = base
        }
        let at = out[0].path
        for (const part of rest.split("/")) {
            if (part.length === 0) continue
            at = Fmt.join(at, part)
            out.push({ path: at, name: part, glyph: "" })
        }
        if (f.mode === "search") out.push({ path: "", name: I18n.tr("Results for “%1”", f.query), glyph: "search" })
        return out
    }

    function edit(): void {
        if (!root.folder) return
        field.text = root.folder.mode === "folder" ? Fmt.pretty(root.folder.path) : ""
        root.editing = true
        field.forceActiveFocus()
        field.selectAll()
    }
    function finish(): void {
        root.editing = false
        if (root.pane) root.pane.forceActiveFocus()
    }
    function resolve(text: string): string {
        let t = text.trim()
        if (t.startsWith("file://")) t = decodeURIComponent(t.slice(7))
        if (t === "~") return Core.home
        if (t.startsWith("~/")) return Fmt.join(Core.home, t.slice(2))
        if (!t.startsWith("/") && root.folder) return Fmt.join(root.folder.mode === "folder" ? root.folder.path : Core.home, t)
        return t
    }
    function go(text: string): void {
        const target = root.resolve(text)
        if (target.length === 0) { root.finish(); return }
        Core.call("stat", { paths: [target] }, r => {
            const e = r.ok ? (r.entries ?? [])[0] : null
            if (!e) { Toast.fail(I18n.tr("Nothing is at %1", Fmt.pretty(target))); return }
            root.finish()
            if (e.dir) root.folder.go(e.path)
            else { root.folder.focusPath = e.path; root.folder.go(Fmt.parent(e.path)) }
        })
    }
    // Tab fills in the folder names that start with what is typed.
    function complete(): void {
        const full = root.resolve(field.text)
        const slash = full.lastIndexOf("/")
        const dir = slash <= 0 ? "/" : full.slice(0, slash)
        const stem = full.slice(slash + 1).toLowerCase()
        Core.call("list", { path: dir, hidden: stem.startsWith("."), counts: false }, r => {
            if (!r.ok) return
            const names = (r.entries ?? []).filter(e => e.dir && e.name.toLowerCase().startsWith(stem)).map(e => e.name)
            if (names.length === 0) return
            let common = names[0]
            for (const n of names) while (!n.toLowerCase().startsWith(common.toLowerCase())) common = common.slice(0, -1)
            const done = Fmt.join(dir, names.length === 1 ? names[0] + "/" : common)
            field.text = done.startsWith(Core.home + "/") ? "~" + done.slice(Core.home.length) : done
            field.cursorPosition = field.text.length
        })
    }

    // ---- the steps
    Flickable {
        id: flick
        anchors.fill: parent
        anchors.leftMargin: Theme.dp(4)
        anchors.rightMargin: Theme.dp(4)
        visible: !root.editing
        clip: true
        contentWidth: steps.width
        contentHeight: height
        interactive: contentWidth > width
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        onContentWidthChanged: Qt.callLater(() => flick.contentX = Math.max(0, flick.contentWidth - flick.width))
        onWidthChanged: Qt.callLater(() => flick.contentX = Math.max(0, flick.contentWidth - flick.width))

        MouseArea {
            width: Math.max(flick.width, steps.width)
            height: flick.height
            onClicked: root.edit()
        }
        Row {
            id: steps
            height: flick.height
            Repeater {
                model: root.crumbs
                delegate: Row {
                    id: crumb
                    required property var modelData
                    required property int index
                    readonly property bool last: crumb.index === root.crumbs.length - 1
                    height: steps.height
                    Glyph {
                        visible: crumb.index > 0
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron_right"
                        size: Theme.dp(16)
                        color: Theme.ink3
                    }
                    Rectangle {
                        id: plate
                        property bool dropping: false
                        anchors.verticalCenter: parent.verticalCenter
                        height: Theme.dp(28)
                        width: inner.width + Theme.dp(16)
                        radius: Theme.dp(9)
                        color: plate.dropping ? Theme.selectionHover : crumbMouse.pressed ? Theme.fillPress : crumbMouse.containsMouse && crumb.modelData.path.length > 0 ? Theme.fillHover : "transparent"
                        Row {
                            id: inner
                            anchors.centerIn: parent
                            spacing: Theme.dp(6)
                            Glyph {
                                visible: crumb.modelData.glyph.length > 0
                                anchors.verticalCenter: parent.verticalCenter
                                name: crumb.modelData.glyph
                                size: Theme.dp(16)
                                fill: crumb.last ? 1 : 0
                                color: crumb.last ? Theme.ink : Theme.ink2
                            }
                            Txt {
                                anchors.verticalCenter: parent.verticalCenter
                                text: crumb.modelData.name
                                size: Theme.row
                                strong: crumb.last
                                color: crumb.last ? Theme.ink : Theme.ink2
                                elide: Text.ElideMiddle
                                width: Math.min(implicitWidth, Theme.dp(220))
                            }
                        }
                        MouseArea {
                            id: crumbMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: crumb.modelData.path.length > 0
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                            onClicked: mouse => {
                                const p = crumb.modelData.path
                                if (mouse.button === Qt.MiddleButton) root.browser.newTab(p)
                                else if (mouse.button === Qt.RightButton) {
                                    const at = crumbMouse.mapToItem(root.browser.stage, mouse.x, mouse.y)
                                    root.browser.actions.placeMenu(p, at.x, at.y)
                                } else if (p !== root.folder.place || root.folder.mode === "search") root.folder.go(p)
                            }
                        }
                        DropArea {
                            anchors.fill: parent
                            enabled: crumb.modelData.path.length > 0 && crumb.modelData.path !== "recent:"
                            onEntered: drag => {
                                if (!drag.hasUrls || root.browser.actions.dropRefused(drag.urls, crumb.modelData.path)) { drag.accepted = false; return }
                                plate.dropping = true
                                spring.restart()
                            }
                            onExited: { plate.dropping = false; spring.stop() }
                            onDropped: drop => { plate.dropping = false; spring.stop(); root.browser.actions.drop(drop, crumb.modelData.path) }
                        }
                        Timer { id: spring; interval: 900; onTriggered: { plate.dropping = false; root.folder.go(crumb.modelData.path) } }
                    }
                }
            }
        }
    }

    // ---- the line
    TextInput {
        id: field
        visible: root.editing
        anchors.fill: parent
        anchors.leftMargin: Theme.dp(12)
        anchors.rightMargin: Theme.dp(12)
        verticalAlignment: TextInput.AlignVCenter
        color: Theme.ink
        selectionColor: Theme.alpha(Theme.accent, 0.45)
        selectedTextColor: Theme.ink
        font.family: Theme.sans
        font.pixelSize: Theme.row
        selectByMouse: true
        clip: true
        onAccepted: root.go(field.text)
        onActiveFocusChanged: if (!activeFocus && root.editing) root.editing = false
        Keys.onEscapePressed: root.finish()
        Keys.onTabPressed: event => { root.complete(); event.accepted = true }
    }
}
