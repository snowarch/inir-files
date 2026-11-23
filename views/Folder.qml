import QtQuick
import qs.services

// One place a pane shows: its entries in order, the way back and forward, and what is chosen. A reload after a change
// on disk updates the rows in place (added, removed, changed), so nothing on screen jumps.
Item {
    id: root
    visible: false

    property string path: Core.home
    property string mode: "folder"          // folder, trash, recent, search
    readonly property string place: root.mode === "folder" ? root.path : root.mode === "search" ? root.searchRoot : root.mode + ":"
    property alias model: entries
    property var all: []
    property var at: ({})
    property bool loading: false
    property string error: ""
    property int hiddenCount: 0
    property bool writable: true
    property var space: ({ total: 0, free: 0 })
    property bool remote: false
    property int loadSerial: 0
    property string focusPath: ""
    property bool selectFirst: false

    property string sortKey: Prefs.get("sort")
    property bool desc: Prefs.get("desc")
    property bool dirsFirst: Prefs.get("dirsFirst")
    property bool showHidden: Prefs.get("hidden")
    onSortKeyChanged: root.reload()
    onDescChanged: root.reload()
    onDirsFirstChanged: root.reload()
    onShowHiddenChanged: root.reload()

    property var back: []
    property var forward: []

    property var selected: ({})
    property int selCount: 0
    property int selRev: 0
    property int current: -1
    property int anchor: -1
    readonly property var currentEntry: { void root.selRev; return root.current >= 0 && root.current < entries.count ? entries.get(root.current) : null }

    property string query: ""
    property string searchRoot: ""
    property bool content: false
    property bool searching: false
    property int scanned: 0
    property string token: ""
    // Every result of the search; all holds those of the kind asked for.
    property var found: []
    property var kindCounts: ({})
    property string kindFilter: ""

    // The core reports changes in the place on screen.
    readonly property string watched: root.mode === "folder" ? root.path : root.mode === "trash" ? (Core.places.trashDir ?? "") : ""
    property string held: ""
    onWatchedChanged: { Core.dropWatch(root.held); root.held = root.watched; Core.holdWatch(root.held) }
    Component.onCompleted: { root.held = root.watched; Core.holdWatch(root.held) }
    Component.onDestruction: Core.dropWatch(root.held)

    signal reset()
    signal revealed(int index)

    ListModel { id: entries }

    readonly property var blank: ({ name: "", path: "", dir: false, link: false, size: 0, mtime: 0, mime: "", kind: "file", icon: "",
        generic: "", hidden: false, exec: false, mode: 0, uid: 0, items: -1, thumb: false, target: "", broken: false, role: "",
        origin: "", deleted: 0, snippet: "", line: 0, comment: "" })
    function normal(e: var): var {
        const o = {}
        for (const k in root.blank) o[k] = e[k] !== undefined && e[k] !== null ? e[k] : root.blank[k]
        return o
    }
    function reindex(): void {
        const m = {}
        for (let i = 0; i < root.all.length; i++) m[root.all[i].path] = i
        root.at = m
    }
    function indexOf(path: string): int { return root.at[path] ?? -1 }

    // ---- going places
    function go(target: string, remember: bool): void {
        if (remember !== false && target !== root.place) {
            root.back = root.back.concat([root.place]).slice(-80)
            root.forward = []
        }
        root.enter(target)
    }
    function enter(target: string): void {
        if (root.mode === "search") root.stopSearch()
        if (target === "trash:" || target === "recent:") {
            root.mode = target.slice(0, -1)
        } else {
            root.mode = "folder"
            root.path = target
        }
        root.query = ""
        root.clearSel()
        root.current = -1
        root.anchor = -1
        root.load(false)
    }
    function goBack(): void {
        if (root.back.length === 0) return
        const to = root.back[root.back.length - 1]
        root.forward = [root.place].concat(root.forward)
        root.back = root.back.slice(0, -1)
        root.focusPath = ""
        root.enter(to)
    }
    function goForward(): void {
        if (root.forward.length === 0) return
        const to = root.forward[0]
        root.back = root.back.concat([root.place])
        root.forward = root.forward.slice(1)
        root.enter(to)
    }
    function goUp(): void {
        if (root.mode !== "folder" || root.path === "/") return
        root.focusPath = root.path
        root.go(Fmt.parent(root.path))
    }

    // ---- reading
    function load(keep: bool): void {
        const serial = ++root.loadSerial
        root.loading = true
        const done = r => root.apply(serial, r, keep)
        if (root.mode === "trash") Core.call("trash_list", {}, done)
        else if (root.mode === "recent") Core.call("recent", {}, done)
        else if (root.mode === "search") root.runSearch()
        else Core.call("list", { path: root.path, hidden: root.showHidden, sort: root.sortKey, desc: root.desc, dirsFirst: root.dirsFirst, counts: Prefs.get("counts") }, done)
    }
    function reload(): void { if (root.mode !== "search") root.load(true) }

    function apply(serial: int, r: var, keep: bool): void {
        if (serial !== root.loadSerial) return
        root.loading = false
        if (!r.ok) {
            // A folder that went away (deleted, unmounted) gives way to the nearest one still there.
            if (keep && r.error === "missing" && root.mode === "folder" && root.path !== "/") {
                root.enter(Fmt.parent(root.path))
                return
            }
            root.error = r.error
            root.all = []
            entries.clear()
            root.reindex()
            root.reset()
            return
        }
        root.error = ""
        if (r.path && root.mode === "folder") root.path = r.path
        root.hiddenCount = r.hidden ?? 0
        root.writable = r.writable ?? (root.mode === "trash")
        root.space = r.space ?? ({ total: 0, free: 0 })
        root.remote = r.remote ?? false
        let list = (r.entries ?? []).map(root.normal)
        if (root.mode !== "folder" && !root.showHidden) list = list.filter(e => !e.hidden || root.mode === "trash")
        if (keep) root.merge(list)
        else {
            root.all = list
            entries.clear()
            entries.append(list)
            root.reindex()
            root.reset()
        }
        // What was selected and still exists stays selected.
        let n = 0
        for (const p in root.selected) {
            if (root.at[p] === undefined) delete root.selected[p]
            else n++
        }
        root.selCount = n
        if (root.focusPath.length > 0) {
            const i = root.indexOf(root.focusPath)
            root.focusPath = ""
            if (i >= 0) root.only(i)
        } else if (root.selectFirst) {
            root.selectFirst = false
            if (entries.count > 0) root.only(0)
        } else if (root.current >= entries.count) root.current = entries.count - 1
        root.selRev++
    }

    // The new list against the rows on screen: both are in the same order, so one pass finds what came and went.
    function merge(list: var): void {
        const fresh = {}
        for (const e of list) fresh[e.path] = true
        let i = 0, j = 0
        while (j < list.length) {
            if (i >= entries.count) {
                entries.append(list.slice(j))
                break
            }
            const have = entries.get(i).path
            const want = list[j]
            if (have === want.path) {
                const row = entries.get(i)
                for (const k in want) if (row[k] !== want[k]) entries.setProperty(i, k, want[k])
                i++; j++
            } else if (!fresh[have]) {
                entries.remove(i)
            } else if (root.at[want.path] === undefined) {
                entries.insert(i, want)
                i++; j++
            } else {
                // Two rows swapped places (a sort key changed): the rest is laid out again.
                entries.remove(i, entries.count - i)
                entries.append(list.slice(j))
                break
            }
        }
        if (entries.count > list.length) entries.remove(list.length, entries.count - list.length)
        root.all = list
        root.reindex()
    }

    // Folder sizes arrive after the listing.
    Connections {
        target: Core
        function onCounts(path, counts) {
            if (root.mode !== "folder" || path !== root.path) return
            for (const name in counts) {
                const i = root.indexOf(Fmt.join(root.path, name))
                if (i >= 0) {
                    entries.setProperty(i, "items", counts[name])
                    root.all[i].items = counts[name]
                }
            }
        }
        function onChanged(paths) {
            if (root.mode === "folder" && paths.indexOf(root.path) >= 0) root.load(true)
            else if (root.mode === "trash" && paths.some(p => p.indexOf("/Trash/") >= 0)) root.load(true)
        }
        function onSearchBatch(b) {
            if (b.token !== root.token) return
            const list = (b.entries ?? []).map(root.normal)
            if (list.length > 0) {
                root.found = root.found.concat(list)
                const counts = Object.assign({}, root.kindCounts)
                for (const e of list) { const g = root.groupOf(e); counts[g] = (counts[g] ?? 0) + 1 }
                root.kindCounts = counts
                const shown = root.kindFilter.length > 0 ? list.filter(root.fits) : list
                if (shown.length > 0) {
                    const start = root.all.length
                    root.all = root.all.concat(shown)
                    entries.append(shown)
                    for (let k = 0; k < shown.length; k++) root.at[shown[k].path] = start + k
                }
            }
            root.scanned = b.scanned ?? root.scanned
            if (b.done) root.searching = false
            if (b.error) Toast.fail(Errors.text(b.error))
        }
        function onReadyChanged() { if (Core.ready && root.error === "core") root.load(false) }
    }

    // ---- search below the folder on screen
    function search(text: string): void {
        if (text.trim().length === 0) {
            if (root.mode === "search") root.stopSearch(true)
            return
        }
        if (root.mode !== "search") {
            root.searchRoot = root.mode === "folder" ? root.path : Core.home
            root.mode = "search"
        }
        root.query = text
        root.runSearch()
    }
    function runSearch(): void {
        if (root.token.length > 0) Core.call("cancel", { token: root.token })
        root.token = "search-" + Math.random().toString(36).slice(2)
        root.clearSel()
        root.current = -1
        root.all = []
        root.at = ({})
        root.found = []
        root.kindCounts = ({})
        entries.clear()
        root.reset()
        root.scanned = 0
        root.searching = true
        root.loading = false
        root.error = ""
        Core.call("search", { token: root.token, root: root.searchRoot, query: root.query, hidden: root.showHidden, content: root.content })
    }
    function stopSearch(back: bool): void {
        if (root.token.length > 0) Core.call("cancel", { token: root.token })
        root.token = ""
        root.searching = false
        root.found = []
        root.kindCounts = ({})
        root.kindFilter = ""
        if (back) {
            root.mode = "folder"
            root.path = root.searchRoot
            root.query = ""
            root.load(false)
        }
    }
    onContentChanged: if (root.mode === "search") root.runSearch()

    // The kind a result counts under in the search's filter.
    function groupOf(e: var): string {
        if (e.dir) return "folder"
        return ({ document: "document", pdf: "document", text: "document", image: "image", video: "video", audio: "audio",
            archive: "archive", disk: "archive", code: "code", executable: "code" })[e.kind] ?? "other"
    }
    function fits(e: var): bool { return root.kindFilter.length === 0 || root.groupOf(e) === root.kindFilter }
    function filterKind(kind: string): void {
        if (root.kindFilter === kind) return
        root.kindFilter = kind
        if (root.mode !== "search") return
        root.clearSel()
        root.current = -1
        root.all = root.found.filter(root.fits)
        entries.clear()
        entries.append(root.all)
        root.reindex()
        root.reset()
    }

    // ---- choosing
    function isSel(path: string): bool { return root.selected[path] === true }
    function clearSel(): void {
        root.selected = ({})
        root.selCount = 0
        root.selRev++
    }
    function only(i: int): void {
        root.selected = ({})
        root.selCount = 0
        root.add(i)
        root.current = i
        root.anchor = i
        root.selRev++
        root.revealed(i)
    }
    function add(i: int): void {
        if (i < 0 || i >= root.all.length) return
        const p = root.all[i].path
        if (!root.selected[p]) { root.selected[p] = true; root.selCount++ }
    }
    function toggle(i: int): void {
        if (i < 0 || i >= root.all.length) return
        const p = root.all[i].path
        if (root.selected[p]) { delete root.selected[p]; root.selCount-- }
        else { root.selected[p] = true; root.selCount++ }
        root.current = i
        root.anchor = i
        root.selRev++
    }
    function range(i: int, additive: bool): void {
        if (!additive) { root.selected = ({}); root.selCount = 0 }
        const a = root.anchor >= 0 ? root.anchor : i
        for (let k = Math.min(a, i); k <= Math.max(a, i); k++) root.add(k)
        root.current = i
        root.selRev++
        root.revealed(i)
    }
    function setSel(indices: var, additive: bool, base: var): void {
        root.selected = additive && base ? Object.assign({}, base) : ({})
        for (const i of indices) if (i >= 0 && i < root.all.length) root.selected[root.all[i].path] = true
        root.selCount = Object.keys(root.selected).length
        root.selRev++
    }
    function selectAll(): void {
        root.selected = ({})
        for (const e of root.all) root.selected[e.path] = true
        root.selCount = root.all.length
        root.selRev++
    }
    function invertSel(): void {
        const next = {}
        for (const e of root.all) if (!root.selected[e.path]) next[e.path] = true
        root.selected = next
        root.selCount = Object.keys(next).length
        root.selRev++
    }
    function selectByPaths(paths: var): void {
        root.selected = ({})
        let first = -1
        for (const p of paths) {
            const i = root.indexOf(p)
            if (i >= 0) { root.selected[p] = true; if (first < 0 || i < first) first = i }
        }
        root.selCount = Object.keys(root.selected).length
        if (first >= 0) { root.current = first; root.anchor = first; root.revealed(first) }
        root.selRev++
    }
    // What an action works on: the chosen ones, or the one under the pointer when it is not among them.
    function chosen(): var {
        void root.selRev
        return root.all.filter(e => root.selected[e.path])
    }
    function chosenPaths(): var { return root.chosen().map(e => e.path) }
    // Moving with the keys: to a row, extending the choice with Shift, carrying only the focus with Ctrl.
    function moveTo(i: int, shift: bool, ctrl: bool): void {
        if (entries.count === 0) return
        i = Math.max(0, Math.min(entries.count - 1, i))
        if (shift) root.range(i, false)
        else if (ctrl) { root.current = i; root.selRev++; root.revealed(i) }
        else root.only(i)
    }
}
