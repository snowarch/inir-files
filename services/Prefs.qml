pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The person's choices (~/.config/inir-files/settings.json) and what the app remembers between runs
// (~/.local/state/inir-files/state.json). Every key has its default here; a key missing on disk reads its default.
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
        zoom: 3,                // grid icon step, 0..6
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
        restoreTabs: true,
        typeAhead: true,
        marks: ({}),            // a bookmark's own look: { path: { glyph, tint } }
        fold: ({})              // rail sections folded away: { bookmarks, devices, network }
    })
    // Read as the app starts (the files block until loaded), so the first window opens with them.
    property var values: root.parse(settingsFile.text())
    property var state: root.parse(stateFile.text())

    function get(key: string): var { return root.values[key] !== undefined ? root.values[key] : root.defaults[key] }
    function set(key: string, value: var): void {
        const next = Object.assign({}, root.values)
        next[key] = value
        root.values = next
        saveSettings.restart()
    }
    function remember(key: string, value: var): void {
        const next = Object.assign({}, root.state)
        next[key] = value
        root.state = next
        saveState.restart()
    }
    function recall(key: string, fallback: var): var { return root.state[key] !== undefined ? root.state[key] : fallback }

    readonly property string scheme: root.get("scheme")
    readonly property real tint: Number(root.get("tint"))
    readonly property real density: Number(root.get("density"))
    readonly property bool motion: root.get("motion") === true

    function parse(text: string): var {
        try { const v = JSON.parse(text); return v && typeof v === "object" ? v : ({}) } catch (e) { return ({}) }
    }

    FileView {
        id: settingsFile
        path: root.configDir + "/settings.json"
        watchChanges: true
        printErrors: false
        atomicWrites: true
        blockLoading: true
        onFileChanged: reload()
        onLoaded: root.values = root.parse(text())
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
        interval: 300
        onTriggered: {
            Quickshell.execDetached(["mkdir", "-p", root.configDir])
            settingsFile.setText(JSON.stringify(root.values, null, 2) + "\n")
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
        if (saveSettings.running) { saveSettings.stop(); settingsFile.setText(JSON.stringify(root.values, null, 2) + "\n") }
        if (saveState.running) { saveState.stop(); stateFile.setText(JSON.stringify(root.state) + "\n") }
    }
}
