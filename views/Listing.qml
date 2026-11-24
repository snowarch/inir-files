import QtQuick
import qs.services

// A folder read for a side column: its entries, kept in step with the disk, without choice or history.
Item {
    id: root
    visible: false
    property string path: ""
    property alias model: entries
    property bool loading: false
    property string error: ""
    property int serial: 0
    property string loadedPath: ""
    property string sortKey: Prefs.get("sort")
    property bool desc: Prefs.get("desc")
    property bool dirsFirst: Prefs.get("dirsFirst")
    property bool showHidden: Prefs.get("hidden")
    // The rows as the model holds them, read in place of the model.
    property var rows: []
    // Rows already known for a path, shown at once while the disk is read again: (path) => rows, or null.
    property var seedOf: null
    // Something to show: rows, or a reading that found none.
    readonly property bool ready: root.rows.length > 0 || (!root.loading && root.serial > 0)
    signal loaded(var rows)

    ListModel { id: entries }

    function replaceModel(list: var): void {
        entries.clear()
        for (let i = 0; i < list.length; i++) entries.append(list[i])
    }

    function load(): void {
        if (root.path.length === 0) { root.loadedPath = ""; root.rows = []; entries.clear(); return }
        const pathChanged = root.loadedPath !== root.path
        root.loadedPath = root.path
        const s = ++root.serial
        root.loading = true
        if (pathChanged || entries.count === 0) {
            const seed = root.seedOf ? root.seedOf(root.path) : null
            if (seed && seed.length > 0) {
                const copy = []
                for (let i = 0; i < seed.length; i++) copy.push(seed[i])
                root.rows = copy
                root.replaceModel(copy)
            }
        }
        Core.call("list", { path: root.path, hidden: root.showHidden, sort: root.sortKey, desc: root.desc, dirsFirst: root.dirsFirst, counts: false }, r => {
            if (!root || s !== root.serial) return
            root.loading = false
            root.error = r.ok ? "" : r.error
            // The keys only some entries carry, so every row has every role.
            const b = { link: false, target: "", broken: false, role: "", appIcon: "", remote: false }
            const list = (r.ok ? (r.entries ?? []) : []).map(e => Object.assign({}, b, e))
            const old = root.rows
            root.rows = list
            // Same rows in the same order: only what changed is touched.
            if (entries.count === list.length && list.length === old.length && list.every((e, i) => old[i].path === e.path)) {
                for (let i = 0; i < list.length; i++) for (const k in list[i]) if (old[i][k] !== list[i][k]) entries.setProperty(i, k, list[i][k])
            } else {
                root.replaceModel(list)
            }
            if (r.ok) root.loaded(list)
        })
    }
    // The folder is watched while it is shown, so what changes in it from anywhere shows in it.
    property string held: ""
    function hold(): void {
        if (root.held === root.path) return
        Core.dropWatch(root.held)
        root.held = root.path
        Core.holdWatch(root.held)
    }
    onPathChanged: { root.hold(); root.load() }
    onSortKeyChanged: if (root.loadedPath.length > 0) root.load()
    onDescChanged: if (root.loadedPath.length > 0) root.load()
    onDirsFirstChanged: if (root.loadedPath.length > 0) root.load()
    onShowHiddenChanged: if (root.loadedPath.length > 0) root.load()
    Component.onCompleted: { root.hold(); if (root.loadedPath !== root.path) root.load() }
    Component.onDestruction: Core.dropWatch(root.held)
    Connections {
        target: Core
        function onChanged(paths) { if (paths.indexOf(root.path) >= 0) root.load() }
    }
}
