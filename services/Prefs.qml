pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The person's choices (~/.config/inir-files/settings.json) and what the app remembers between runs
// (~/.local/state/inir-files/state.json). Each key is its own reactive property so changing one (like zoom) never
// re-evaluates unrelated bindings across windows.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") ?? ""
    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (root.home + "/.config")) + "/inir-files"
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")) + "/inir-files"

    readonly property var defaults: ({
        scheme: "system",       // system, dark, light
        tint: 0.55,             // how much of the desktop's colour reaches the ground
        density: 1,             // 0.9 compact, 1 regular, 1.1 roomy
        motion: true,
        view: "grid",           // grid, list, columns, gallery
        zoom: 3,                // grid icon step, 1..7
        listZoom: 1,            // list row step, 0..2
        sort: "name",           // name, size, mtime, kind, ext
        desc: false,
        dirsFirst: true,
        hidden: false,
        icons: "drawn",         // drawn, system
        thumbnails: "local",    // all, local, never
        thumbLimit: 200,        // MB: larger files get no thumbnail
        covers: true,           // a folder shows a picture it holds
        singleClick: false,
        confirmTrash: false,
        terminal: "",           // empty: the first terminal found
        aside: true,
        rail: true,
        counts: true,
        start: true,
        startSections: ({ banner: true, places: true, drives: true, recent: true, bookmarks: false }),
        restoreTabs: true,
        typeAhead: true,
        localsend: true,        // auto-discover & receive LocalSend v2.1 devices on LAN
        localsendAutoAccept: false,
        localsendAlias: "",
        marks: ({}),            // a bookmark's own look: { path: { glyph, tint } }
        fold: ({})              // rail sections folded away: { bookmarks, devices, network }
    })

    // Read synchronously once on startup so the first frame uses the saved choices.
    property var values: root.parse(settingsFile.text())
    property var state: root.parse(stateFile.text())
    property string lastSaved: ""

    function initVal(key: string): var { return root.values[key] !== undefined ? root.values[key] : root.defaults[key] }

    // Individual reactive properties: Prefs.get(key) subscribes only to root[key], never to all of values.
    property string scheme: String(root.initVal("scheme"))
    property real tint: Number(root.initVal("tint"))
    property real density: Number(root.initVal("density"))
    property bool motion: root.initVal("motion") === true
    property string view: String(root.initVal("view"))
    property int zoom: Number(root.initVal("zoom"))
    property int listZoom: Number(root.initVal("listZoom"))
    property string sort: String(root.initVal("sort"))
    property bool desc: root.initVal("desc") === true
    property bool dirsFirst: root.initVal("dirsFirst") === true
    property bool hidden: root.initVal("hidden") === true
    property string icons: String(root.initVal("icons"))
    property string thumbnails: String(root.initVal("thumbnails"))
    property real thumbLimit: Number(root.initVal("thumbLimit"))
    property bool covers: root.initVal("covers") === true
    property bool singleClick: root.initVal("singleClick") === true
    property bool confirmTrash: root.initVal("confirmTrash") === true
    property string terminal: String(root.initVal("terminal"))
    property bool aside: root.initVal("aside") === true
    property bool rail: root.initVal("rail") === true
    property bool counts: root.initVal("counts") === true
    property bool start: root.initVal("start") === true
    property var startSections: root.initVal("startSections")
    property bool restoreTabs: root.initVal("restoreTabs") === true
    property bool typeAhead: root.initVal("typeAhead") === true
    property bool localsend: root.initVal("localsend") === true
    property bool localsendAutoAccept: root.initVal("localsendAutoAccept") === true
    property string localsendAlias: String(root.initVal("localsendAlias"))
    property var marks: root.initVal("marks")
    property var fold: root.initVal("fold")

    function get(key: string): var {
        if (root.defaults[key] !== undefined) return root[key]
        return root.values[key]
    }
    function set(key: string, value: var): void {
        if (root.defaults[key] !== undefined) {
            if (typeof value !== "object" && root[key] === value) return
            root[key] = value
        }
        root.values[key] = value
        saveSettings.restart()
    }
    function applyExternal(parsed: var): void {
        root.values = parsed
        for (const k in root.defaults) {
            const want = parsed[k] !== undefined ? parsed[k] : root.defaults[k]
            if (typeof want === "object") {
                if (JSON.stringify(root[k]) !== JSON.stringify(want)) root[k] = want
            } else if (root[k] !== want) {
                root[k] = want
            }
        }
    }

    function remember(key: string, value: var): void {
        const next = Object.assign({}, root.state)
        next[key] = value
        root.state = next
        saveState.restart()
    }
    function recall(key: string, fallback: var): var { return root.state[key] !== undefined ? root.state[key] : fallback }

    function parse(text: string): var {
        try { const v = JSON.parse(text); return v && typeof v === "object" ? v : ({}) } catch (e) { return ({}) }
    }
    function writeSettingsNow(): void {
        const out = JSON.stringify(root.values, null, 2) + "\n"
        root.lastSaved = out
        settingsFile.setText(out)
    }

    FileView {
        id: settingsFile
        path: root.configDir + "/settings.json"
        watchChanges: true
        printErrors: false
        atomicWrites: true
        blockLoading: true
        onFileChanged: reload()
        onLoaded: {
            const raw = text()
            // Ignore our own write bouncing back from inotify.
            if (raw === root.lastSaved) return
            root.applyExternal(root.parse(raw))
        }
    }
    FileView {
        id: stateFile
        path: root.stateDir + "/state.json"
        printErrors: false
        atomicWrites: true
        blockLoading: true
        onLoaded: root.state = root.parse(text())
    }
    Timer {
        id: saveSettings
        interval: 350
        onTriggered: {
            Quickshell.execDetached(["mkdir", "-p", root.configDir])
            root.writeSettingsNow()
        }
    }
    Timer {
        id: saveState
        interval: 600
        onTriggered: {
            Quickshell.execDetached(["mkdir", "-p", root.stateDir])
            stateFile.setText(JSON.stringify(root.state) + "\n")
        }
    }
    // A last write before the app quits.
    function flush(): void {
        if (saveSettings.running) { saveSettings.stop(); root.writeSettingsNow() }
        if (saveState.running) { saveState.stop(); stateFile.setText(JSON.stringify(root.state) + "\n") }
    }
}
