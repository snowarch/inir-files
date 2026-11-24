import QtQuick
import Quickshell
import qs.services
import qs.kit

// What the window does to files, in one place: what the menus offer, what keys and drops start, and the questions a
// change asks first. The views call these; the core does the work.
Item {
    id: root
    required property var browser
    readonly property var menus: root.browser.menus
    readonly property int clipRev: Core.clipRev
    property var templates: []

    Component.onCompleted: Core.call("templates", {}, r => { if (r.ok) root.templates = r.templates })

    // ---- small things
    function fail(error: string): void { Toast.fail(Errors.text(error)) }
    function here(pane: var): string { return pane && pane.folder.mode === "folder" ? pane.folder.path : "" }
    function chosenOrHere(pane: var): var {
        const p = pane.folder.chosenPaths()
        return p.length > 0 ? p : root.here(pane).length > 0 ? [root.here(pane)] : []
    }
    function pathsOf(urls: var): var {
        const out = []
        for (let i = 0; i < urls.length; i++) {
            const s = String(urls[i])
            if (s.startsWith("file://")) out.push(decodeURIComponent(s.slice(s.indexOf("/", 7))))
        }
        return out
    }
    function terminalCommand(): string { return Prefs.get("terminal") ?? "" }
    function sheet(component: Component, props: var): var { return root.browser.sheet(component, props ?? {}) }
    function job(op: string, args: var, say: string): void { Core.job(op, args, { owner: root.browser, say: say }) }
    // A new file or folder: chosen when it shows, named at once if asked, and gone again by an undo.
    function created(pane: var, path: string, rename: bool): void {
        pane.folder.focusPath = path
        if (rename) root.browser.renaming = path
        pane.folder.reload()
        Undo.push({ job: true, what: "new", op: "trash", args: { paths: [path] } })
    }

    // ---- the clipboard
    function isCut(path: string): bool { return Core.cutPaths[path] === true }
    function copy(pane: var): void {
        const paths = pane.folder.chosenPaths()
        if (paths.length === 0) return
        Core.call("clip_set", { paths: paths }, r => {
            if (!r.ok) return root.fail(r.error)
            Core.setCut([])
            Toast.show(I18n.n("%1 item copied", "%1 items copied", paths.length), "", null)
        })
    }
    function cut(pane: var): void {
        const paths = pane.folder.chosenPaths()
        if (paths.length === 0 || pane.folder.mode === "trash") return
        Core.call("clip_set", { paths: paths }, r => {
            if (!r.ok) return root.fail(r.error)
            Core.setCut(paths)
            Toast.show(I18n.n("%1 item cut: paste it where it goes", "%1 items cut: paste them where they go", paths.length), "", null)
        })
    }
    function paste(pane: var, into: string): void {
        const dest = into && into.length > 0 ? into : root.here(pane)
        if (dest.length === 0) return
        Core.call("clip_get", {}, r => {
            if (!r.ok) return root.fail(r.error)
            if (r.paths.length > 0) {
                if (r.cut || r.paths.every(p => Core.cutPaths[p])) {
                    root.job("move", { paths: r.paths, dest: dest }, I18n.n("%1 item moved", "%1 items moved", r.paths.length))
                    Core.setCut([])
                } else root.job("copy", { paths: r.paths, dest: dest }, I18n.n("%1 item copied", "%1 items copied", r.paths.length))
                return
            }
            const mime = r.image ?? (r.text ? (r.types.find(t => t.startsWith("text/plain")) ?? "UTF8_STRING") : "")
            if (!mime) return root.fail("empty")
            Core.call("clip_save", { dir: dest, mime: mime, name: r.image ? I18n.tr("Pasted image") : I18n.tr("Pasted text") }, s => {
                if (!s.ok) return root.fail(s.error)
                root.created(pane, s.path, false)
            })
        })
    }
    function copyText(text: string): void {
        Core.call("clip_set", { text: text }, r => r.ok ? Toast.show(I18n.tr("Copied"), "", null) : root.fail(r.error))
    }
    function copyPath(pane: var): void { root.copyText(root.chosenOrHere(pane).join("\n")) }

    // ---- sending: the chosen moved or copied to a folder at hand, with no second window to open
    // Where they can go: the other side of a split, the folders sent to last, the bookmarks, a mounted drive one can
    // unplug, home. Each once, never the folder they are in, nor one inside what goes.
    function destinations(pane: var, paths: var): var {
        const out = [], seen = {}
        const from = root.here(pane)
        const home = Core.places.home || Core.home
        const looks = Prefs.get("marks") ?? {}
        const marks = {}, drives = {}
        for (const b of Core.places.bookmarks) if (!b.remote && b.exists) marks[b.path] = b
        for (const d of Core.places.devices) if (d.removable && d.mounted && !d.readonly) drives[d.path] = d.label || d.model || Fmt.name(d.path)
        // Under each name, the folder it is in, short: a recent folder may share its name with another.
        const where = path => {
            const up = Fmt.parent(path), shown = Fmt.pretty(up)
            return shown.length <= 22 ? shown : "…/" + Fmt.name(up)
        }
        const add = (path, glyph, tint, bare) => {
            if (!path || seen[path] || path === from || paths.some(p => p === path || path.startsWith(p + "/"))) return
            seen[path] = true
            const name = path === home ? I18n.tr("Home") : marks[path]?.name ?? drives[path] ?? Fmt.name(path)
            out.push({ path: path, name: name, glyph: glyph, note: bare || path === home ? "" : where(path), tint: tint ? Theme.tints[tint] : undefined })
        }
        const other = root.browser.currentPage?.otherPane(pane)
        if (other && other.folder.mode === "folder") add(other.folder.path, "vertical_split")
        for (const p of Prefs.recall("sentTo", [])) add(p, "history")
        for (const p in marks) add(p, looks[p]?.glyph ?? "bookmark", looks[p]?.tint)
        for (const p in drives) add(p, "usb", undefined, true)
        add(home, "home")
        return out
    }
    function sendEntries(pane: var, paths: var, op: string): var {
        return root.destinations(pane, paths).map(d => ({ text: d.name, glyph: d.glyph, note: d.note, tint: d.tint, run: () => root.send(paths, d.path, op) }))
    }
    function send(paths: var, dest: string, op: string): void {
        const n = paths.length
        root.job(op, { paths: paths, dest: dest }, op === "move" ? I18n.n("%1 item moved", "%1 items moved", n) : I18n.n("%1 item copied", "%1 items copied", n))
        Prefs.remember("sentTo", [dest].concat(Prefs.recall("sentTo", []).filter(p => p !== dest)).slice(0, 4))
    }

    // ---- drag and drop
    // True when the drop makes no sense: nothing local, a folder into itself, files into the folder they are in.
    function dropRefused(urls: var, dest: string): bool {
        const paths = root.pathsOf(urls)
        if (paths.length === 0) return true
        if (dest === "trash:") return paths.every(p => p.indexOf("/.local/share/Trash/") >= 0)
        for (const p of paths) if (p === dest || dest.startsWith(p + "/")) return true
        return paths.every(p => Fmt.parent(p) === dest)
    }
    // Ctrl copies, Ctrl+Shift links, a plain drop moves on the same disk and copies across disks.
    function drop(drop: var, dest: string): void {
        const paths = root.pathsOf(drop.urls)
        if (paths.length === 0 || root.dropRefused(drop.urls, dest)) return
        const n = paths.length
        if (dest === "trash:") {
            root.job("trash", { paths: paths }, I18n.n("%1 item moved to the trash", "%1 items moved to the trash", n))
            drop.accept(Qt.MoveAction)
            return
        }
        const action = drop.proposedAction
        if (action === Qt.LinkAction) root.job("link", { paths: paths, dest: dest }, I18n.n("%1 link made", "%1 links made", n))
        else if (action === Qt.CopyAction) root.job("copy", { paths: paths, dest: dest }, I18n.n("%1 item copied", "%1 items copied", n))
        else Core.call("samefs", { paths: paths, dest: dest }, r => {
            if (r.ok && r.same) root.job("move", { paths: paths, dest: dest }, I18n.n("%1 item moved", "%1 items moved", n))
            else root.job("copy", { paths: paths, dest: dest }, I18n.n("%1 item copied", "%1 items copied", n))
        })
        drop.accept(action === Qt.LinkAction ? Qt.LinkAction : Qt.CopyAction)
    }

    // ---- opening
    function open(pane: var, list: var): void {
        const f = pane.folder
        if (!list || list.length === 0) return
        if (f.mode === "trash") { root.browser.quickLook.toggle(pane); return }
        const dirs = list.filter(e => e.dir)
        const files = list.filter(e => !e.dir)
        if (dirs.length === 1 && files.length === 0) { f.go(dirs[0].path); return }
        for (const d of dirs) root.browser.newTab(d.path)
        if (files.length === 1 && files[0].kind === "executable") { root.askRun(files[0]); return }
        if (files.length > 0) root.openFiles(files.map(e => e.path))
    }
    function openFiles(paths: var): void {
        Core.call("open", { paths: paths, terminal: root.terminalCommand() }, r => {
            if (r.ok) return
            if (r.error === "noapp") root.chooseApp(paths)
            else root.fail(r.error)
        })
    }
    function openWith(paths: var, app: string): void {
        Core.call("open", { paths: paths, app: app, terminal: root.terminalCommand() }, r => { if (!r.ok) root.fail(r.error) })
    }
    function chooseApp(paths: var): void { root.sheet(appsSheet, { paths: paths }) }
    function askRun(e: var): void {
        root.sheet(confirmSheet, {
            title: I18n.tr("Run “%1”?", e.name),
            subtitle: I18n.tr("It is a program. It runs with your rights."),
            choices: [
                { text: I18n.tr("Open"), run: () => root.openFiles([e.path]) },
                { text: I18n.tr("Run in terminal"), run: () => Core.call("run", { path: e.path, terminal: true, terminalCommand: root.terminalCommand() }, r => { if (!r.ok) root.fail(r.error) }) },
                { text: I18n.tr("Run"), kind: "solid", run: () => Core.call("run", { path: e.path, terminal: false }, r => { if (!r.ok) root.fail(r.error) }) }
            ]
        })
    }
    // The apps for a kind of file, the usual one first; Core answers before the menu shows.
    function withApps(list: var, done: var): void {
        const files = list.filter(e => !e.dir || list.length === 1)
        const mime = files.length > 0 && files.every(e => e.mime === files[0].mime) ? files[0].mime : ""
        if (mime.length === 0) { done([]); return }
        Core.call("apps", { mime: mime }, r => {
            if (!r.ok) { done([]); return }
            const paths = list.map(e => e.path)
            const apps = r.apps.slice(0, 12).map(a => ({ text: a.name, icon: a.icon ? Quickshell.iconPath(a.icon, true) : "", glyph: "apps", checked: a.id === r.default, run: () => root.openWith(paths, a.id) }))
            done(apps)
        })
    }
    function openWithEntries(list: var, apps: var): var {
        const paths = list.map(e => e.path)
        return apps.concat(apps.length > 0 ? [{ separator: true }] : []).concat([{ text: I18n.tr("Other app…"), glyph: "apps", run: () => root.chooseApp(paths) }])
    }
    function openWithMenu(list: var, item: Item): void {
        root.withApps(list, apps => root.menus.openAt(root.openWithEntries(list, apps), item, true))
    }
    function setWallpaper(path: string): void {
        Core.call("wallpaper", { path: path }, r => { if (!r.ok) root.fail(r.error) })
    }
    function terminal(dir: string): void {
        Core.call("terminal", { dir: dir, terminal: root.terminalCommand() }, r => { if (!r.ok) root.fail(r.error) })
    }

    // ---- making and naming
    function newFolder(pane: var): void {
        const dir = root.here(pane)
        if (dir.length === 0) return
        Core.call("mkdir", { dir: dir, name: I18n.tr("New folder") }, r => r.ok ? root.created(pane, r.path, true) : root.fail(r.error))
    }
    function newFile(pane: var, template: string): void {
        const dir = root.here(pane)
        if (dir.length === 0) return
        const args = template.length > 0 ? { dir: dir, template: template } : { dir: dir, name: I18n.tr("New document") }
        Core.call("newfile", args, r => r.ok ? root.created(pane, r.path, true) : root.fail(r.error))
    }
    function rename(pane: var): void {
        const list = pane.folder.chosen()
        if (list.length === 0 || pane.folder.mode === "trash") return
        if (list.length === 1) {
            pane.folder.revealed(pane.folder.indexOf(list[0].path))
            root.browser.renaming = list[0].path
        } else root.sheet(renameSheet, { entries: list, pane: pane })
    }
    function renameTo(path: string, name: string): void {
        const pane = root.browser.activePane
        root.browser.renaming = ""
        if (name.length === 0 || name === Fmt.name(path)) { if (pane) pane.forceActiveFocus(); return }
        Core.call("rename", { path: path, name: name }, r => {
            if (!r.ok) return root.fail(r.error)
            if (pane) { pane.folder.focusPath = r.to; pane.folder.reload(); pane.forceActiveFocus() }
            Undo.push(Undo.renamed(r))
        })
    }
    function renameCancelled(pane: var): void {
        root.browser.renaming = ""
        if (pane) pane.forceActiveFocus()
    }
    function duplicate(pane: var): void {
        const paths = pane.folder.chosenPaths()
        if (paths.length > 0) root.job("duplicate", { paths: paths }, I18n.n("%1 item duplicated", "%1 items duplicated", paths.length))
    }
    function link(pane: var): void {
        const paths = pane.folder.chosenPaths()
        if (paths.length > 0) root.job("link", { paths: paths, dest: root.here(pane) }, I18n.n("%1 link made", "%1 links made", paths.length))
    }
    function compress(pane: var): void {
        const list = pane.folder.chosen()
        if (list.length > 0) root.sheet(compressSheet, { paths: list.map(e => e.path), dir: root.here(pane), suggested: list.length === 1 ? list[0].name.slice(0, list[0].dir ? list[0].name.length : Fmt.stem(list[0].name)) : Fmt.name(root.here(pane)) })
    }
    function extract(pane: var, password: string): void {
        const list = pane.folder.chosen().filter(e => e.kind === "archive" || e.kind === "disk")
        if (list.length > 0) root.extractTo(list.map(e => e.path), root.here(pane), password)
    }
    function extractTo(paths: var, dest: string, password: string): void {
        const args = { paths: paths, dest: dest }
        if (password.length > 0) args.password = password
        root.job("extract", args, I18n.n("%1 archive extracted", "%1 archives extracted", paths.length))
    }

    // ---- taking away
    function trash(pane: var): void {
        const f = pane.folder
        const paths = f.chosenPaths()
        if (paths.length === 0) return
        if (f.mode === "trash") { root.purge(pane); return }
        const go = () => root.job("trash", { paths: paths }, I18n.n("%1 item moved to the trash", "%1 items moved to the trash", paths.length))
        if (!Prefs.get("confirmTrash")) { go(); return }
        root.sheet(confirmSheet, {
            title: paths.length === 1 ? I18n.tr("Move “%1” to the trash?", Fmt.name(paths[0])) : I18n.n("Move %1 item to the trash?", "Move %1 items to the trash?", paths.length),
            choices: [{ text: I18n.tr("Move to trash"), kind: "solid", run: go }]
        })
    }
    function deleteForever(pane: var): void {
        const paths = pane.folder.chosenPaths()
        if (paths.length === 0) return
        if (pane.folder.mode === "trash") { root.purge(pane); return }
        root.askDelete(paths, "delete")
    }
    function askDelete(paths: var, op: string): void {
        root.sheet(confirmSheet, {
            title: paths.length === 1 ? I18n.tr("Delete “%1” forever?", Fmt.name(paths[0])) : I18n.n("Delete %1 item forever?", "Delete %1 items forever?", paths.length),
            subtitle: I18n.tr("It cannot come back."),
            choices: [{ text: I18n.tr("Delete"), kind: "danger", run: () => Core.job(op, { paths: paths }, { owner: root.browser, undoable: false, say: I18n.n("%1 item deleted", "%1 items deleted", paths.length) }) }]
        })
    }
    function purge(pane: var): void { const p = pane.folder.chosenPaths(); if (p.length > 0) root.askDelete(p, "purge") }
    function restore(pane: var): void {
        const paths = pane.folder.chosenPaths()
        if (paths.length > 0) Core.job("restore", { paths: paths }, { owner: root.browser, say: I18n.n("%1 item put back", "%1 items put back", paths.length) })
    }
    function emptyTrash(): void {
        root.sheet(confirmSheet, {
            title: I18n.tr("Empty the trash?"),
            subtitle: I18n.tr("All items in the trash will be deleted forever."),
            choices: [{ text: I18n.tr("Empty trash"), kind: "danger", run: () => Core.job("emptytrash", {}, { owner: root.browser, undoable: false, say: I18n.tr("The trash is empty") }) }]
        })
    }

    // ---- places
    function bookmark(path: string): void {
        Core.call("bookmark_add", { path: path }, r => { if (!r.ok) return root.fail(r.error); Core.takeBookmarks(r); Toast.show(I18n.tr("“%1” added to bookmarks", Fmt.name(path)), "", null) })
    }
    // Dropped folders join the bookmarks at `at` (an index of the whole bookmarks file), or at the end.
    function bookmarkDropped(drop: var, at: int): void {
        const paths = root.pathsOf(drop.urls)
        if (paths.length === 0) return
        drop.accept(Qt.LinkAction)
        Core.call("stat", { paths: paths }, r => {
            if (!r.ok) return
            const dirs = r.entries.filter(e => e.dir)
            dirs.forEach((e, i) => Core.call("bookmark_add", at >= 0 ? { path: e.path, at: at + i } : { path: e.path }, b => Core.takeBookmarks(b)))
        })
    }
    function renameBookmark(it: var): void {
        root.sheet(confirmSheet, {
            title: I18n.tr("Rename bookmark"),
            field: true,
            fieldText: it.name ?? it.label ?? Fmt.name(it.path),
            choices: [{ text: I18n.tr("Rename"), kind: "solid", run: text => Core.call("bookmark_rename", { path: it.path, name: text }, r => Core.takeBookmarks(r)) }]
        })
    }
    function propertiesOf(paths: var): void { if (paths.length > 0) root.sheet(propertiesSheet, { paths: paths }) }
    function properties(pane: var): void { root.propertiesOf(root.chosenOrHere(pane)) }
    function settings(): void { root.sheet(settingsSheet, {}) }
    function undo(): void { if (Undo.can) Undo.undo(root.browser) }
    function redo(): void { if (Undo.canRedo) Undo.redo(root.browser) }
    // One connection at a time: a second click on a server while the first waits does nothing.
    property var connecting: null
    function connect(address: var, newTab: var): void {
        if (root.connecting) return
        root.connecting = root.sheet(connectSheet, { address: address ?? "", newTab: newTab === true, delay: address ? 300 : 0 })
        if (root.connecting) root.connecting.dismissed.connect(() => root.connecting = null)
    }
    function selectByName(pane: var): void { if (pane) root.sheet(selectSheet, { pane: pane }) }

    // ---- how the files show
    function setView(value: string): void { Prefs.set("view", value) }
    function sortBy(key: string): void {
        if (Prefs.get("sort") === key) Prefs.set("desc", !Prefs.get("desc"))
        else { Prefs.set("sort", key); Prefs.set("desc", key === "mtime" || key === "size") }
    }
    // The grid and the gallery share their zoom; the list and the columns share theirs.
    function zoomKey(): string { return ["grid", "gallery"].includes(Prefs.get("view")) ? "zoom" : "listZoom" }
    function zoom(step: int): void {
        if (root.zoomKey() === "zoom") Prefs.set("zoom", Math.max(1, Math.min(7, Number(Prefs.get("zoom")) + step)))
        else Prefs.set("listZoom", Math.max(0, Math.min(2, Number(Prefs.get("listZoom")) + step)))
    }
    function resetZoom(): void {
        const key = root.zoomKey()
        Prefs.set(key, Prefs.defaults[key])
    }

    // ---- menus
    function sortEntries(): var {
        const key = Prefs.get("sort")
        const by = (k, text, glyph) => ({ text: text, glyph: glyph, checked: key === k, run: () => Prefs.set("sort", k) })
        return [
            { header: I18n.tr("Sort by") },
            by("name", I18n.tr("Name"), "sort_by_alpha"),
            by("mtime", I18n.tr("Modified"), "schedule"),
            by("size", I18n.tr("Size"), "straighten"),
            by("kind", I18n.tr("Kind"), "category"),
            by("ext", I18n.tr("Extension"), "label"),
            { separator: true },
            { text: I18n.tr("Reverse order"), glyph: "swap_vert", checked: Prefs.get("desc") === true, run: () => Prefs.set("desc", !Prefs.get("desc")) },
            { text: I18n.tr("Folders first"), glyph: "folder", checked: Prefs.get("dirsFirst") === true, run: () => Prefs.set("dirsFirst", !Prefs.get("dirsFirst")) }
        ]
    }
    function viewEntries(): var {
        const v = Prefs.get("view")
        return [
            { text: I18n.tr("Grid"), glyph: "grid_view", keys: "Ctrl+1", checked: v === "grid", run: () => root.setView("grid") },
            { text: I18n.tr("List"), glyph: "view_list", keys: "Ctrl+2", checked: v === "list", run: () => root.setView("list") },
            { text: I18n.tr("Columns"), glyph: "view_column", keys: "Ctrl+3", checked: v === "columns", run: () => root.setView("columns") },
            { text: I18n.tr("Gallery"), glyph: "photo_library", keys: "Ctrl+4", checked: v === "gallery", run: () => root.setView("gallery") }
        ]
    }
    function newEntries(pane: var): var {
        const out = [{ text: I18n.tr("Empty file"), glyph: "draft", run: () => root.newFile(pane, "") }]
        if (root.templates.length > 0) out.push({ separator: true })
        for (const t of root.templates) out.push({ text: t.name, glyph: "description", run: () => root.newFile(pane, t.path) })
        return out
    }
    function moreEntries(pane: var, compact: bool): var {
        const page = root.browser.currentPage
        const start = pane && pane.folder.mode === "start"
        const view = compact && !start ? [{ text: I18n.tr("View"), glyph: "grid_view", sub: root.viewEntries() }] : []
        return view.concat([
            { text: I18n.tr("New folder"), glyph: "create_new_folder", keys: "Ctrl+Shift+N", enabled: root.here(pane).length > 0, run: () => root.newFolder(pane) },
            { text: I18n.tr("New tab"), glyph: "tab", keys: "Ctrl+T", run: () => root.browser.newTab(pane.folder.place) },
            { text: I18n.tr("Duplicate tab"), glyph: "tab_duplicate", keys: "Ctrl+Shift+D", run: () => root.browser.duplicateTab(root.browser.tabIndex) },
            root.browser.tabs.length > 1 ? { text: I18n.tr("Move tab to new window"), glyph: "open_in_new", keys: "Ctrl+Alt+W", run: () => root.browser.detachTab(root.browser.tabIndex) } : null,
            { text: I18n.tr("New window"), glyph: "open_in_new", keys: "Ctrl+N", run: () => root.browser.newWindow(pane.folder.place) },
            { text: I18n.tr("Reopen closed tab"), glyph: "restore_page", keys: "Ctrl+Shift+T", enabled: root.browser.closedTabs.length > 0, run: () => root.browser.reopenTab() },
            { text: I18n.tr("Split view"), glyph: "vertical_split", keys: "F3", checked: page ? page.split : false, run: () => page && page.toggleSplit() },
            { text: I18n.tr("Connect to server…"), glyph: "add_link", run: () => root.connect("", false) },
            { separator: true },
            { text: I18n.tr("Show hidden files"), glyph: "visibility", keys: "Ctrl+H", checked: Prefs.get("hidden") === true, run: () => Prefs.set("hidden", !Prefs.get("hidden")) },
            { text: I18n.tr("Select all"), glyph: "select_all", keys: "Ctrl+A", enabled: !start, run: () => pane.folder.selectAll() },
            { text: I18n.tr("Invert selection"), glyph: "flip", keys: "Ctrl+Shift+I", enabled: !start, run: () => pane.folder.invertSel() },
            { text: I18n.tr("Select by name…"), glyph: "checklist", keys: "Ctrl+S", enabled: !start, run: () => root.selectByName(pane) },
            { separator: true },
            { text: Undo.can ? Undo.label : I18n.tr("Undo"), glyph: "undo", keys: "Ctrl+Z", enabled: Undo.can, run: () => root.undo() },
            { text: Undo.canRedo ? Undo.redoLabel : I18n.tr("Redo"), glyph: "redo", keys: "Ctrl+Shift+Z", enabled: Undo.canRedo, run: () => root.redo() },
            { text: I18n.tr("Settings"), glyph: "settings", keys: "Ctrl+,", run: () => root.settings() }
        ])
    }
    function backgroundMenu(pane: var, x: real, y: real): void {
        const f = pane.folder
        pane.activate()
        if (f.mode === "trash") {
            root.menus.open([
                { text: I18n.tr("Empty trash"), glyph: "delete_forever", danger: true, enabled: f.model.count > 0, run: () => root.emptyTrash() },
                { text: I18n.tr("Select all"), glyph: "select_all", keys: "Ctrl+A", run: () => f.selectAll() },
                { separator: true },
                { text: I18n.tr("Sort by"), glyph: "sort", sub: root.sortEntries() },
                { text: I18n.tr("View"), glyph: "grid_view", sub: root.viewEntries() }
            ], x, y)
            return
        }
        const dir = root.here(pane)
        const writable = dir.length > 0 && f.writable
        root.menus.open([
            { text: I18n.tr("New folder"), glyph: "create_new_folder", keys: "Ctrl+Shift+N", enabled: writable, run: () => root.newFolder(pane) },
            { text: I18n.tr("New file"), glyph: "note_add", enabled: writable, sub: root.newEntries(pane) },
            { text: I18n.tr("Paste"), glyph: "content_paste", keys: "Ctrl+V", enabled: writable, run: () => root.paste(pane, "") },
            { separator: true },
            { text: I18n.tr("Select all"), glyph: "select_all", keys: "Ctrl+A", run: () => f.selectAll() },
            { text: I18n.tr("Sort by"), glyph: "sort", sub: root.sortEntries() },
            { text: I18n.tr("View"), glyph: "grid_view", sub: root.viewEntries() },
            { text: I18n.tr("Show hidden files"), glyph: "visibility", keys: "Ctrl+H", checked: Prefs.get("hidden") === true, run: () => Prefs.set("hidden", !Prefs.get("hidden")) },
            { separator: true },
            { text: I18n.tr("Open in terminal"), glyph: "terminal", keys: "F4", enabled: dir.length > 0, run: () => root.terminal(dir) },
            { text: I18n.tr("Add to bookmarks"), glyph: "bookmark_add", keys: "Ctrl+B", enabled: dir.length > 0, run: () => root.bookmark(dir) },
            { text: I18n.tr("Copy path"), glyph: "content_copy", enabled: dir.length > 0, run: () => root.copyText(dir) },
            { text: I18n.tr("Properties"), glyph: "info", keys: "Alt+Enter", enabled: dir.length > 0, run: () => root.propertiesOf([dir]) }
        ], x, y)
    }
    function itemMenu(pane: var, x: real, y: real): void {
        const f = pane.folder
        const list = f.chosen()
        if (list.length === 0) { root.backgroundMenu(pane, x, y); return }
        pane.activate()
        const one = list.length === 1 ? list[0] : null
        const paths = list.map(e => e.path)
        if (f.mode === "trash") {
            root.menus.open([
                { text: I18n.tr("Put back"), glyph: "restore_from_trash", run: () => root.restore(pane) },
                { text: I18n.tr("Delete forever"), glyph: "delete_forever", keys: "Delete", danger: true, run: () => root.purge(pane) },
                { separator: true },
                { text: I18n.tr("Quick look"), glyph: "visibility", keys: "Space", run: () => root.browser.quickLook.toggle(pane) }
            ], x, y)
            return
        }
        root.withApps(list, apps => {
            const dirs = list.filter(e => e.dir)
            const archives = list.filter(e => e.kind === "archive")
            const writable = f.mode !== "folder" || f.writable
            const out = []
            out.push({ text: I18n.tr("Open"), glyph: "open_in_new", keys: "Enter", run: () => root.open(pane, list) })
            if (dirs.length > 0) {
                out.push({ text: I18n.tr("Open in new tab"), glyph: "tab", keys: "Ctrl+Enter", run: () => { for (const d of dirs) root.browser.newTab(d.path) } })
                if (one) out.push({ text: I18n.tr("Open in new window"), glyph: "open_in_browser", run: () => root.browser.newWindow(one.path) })
            }
            if (dirs.length === 0 || one) out.push({ text: I18n.tr("Open with"), glyph: "apps", sub: root.openWithEntries(list, apps) })
            if (one && (one.kind === "image" || one.kind === "video")) out.push({ text: I18n.tr("Set as wallpaper"), glyph: "wallpaper", run: () => root.setWallpaper(one.path) })
            if (f.mode === "search" || f.mode === "recent" || f.mode === "start") out.push({ text: I18n.tr("Show in folder"), glyph: "folder_open", enabled: !!one, run: () => { f.go(Fmt.parent(one.path)); f.focusPath = one.path } })
            out.push({ separator: true })
            out.push({ text: I18n.tr("Cut"), glyph: "content_cut", keys: "Ctrl+X", enabled: writable, run: () => root.cut(pane) })
            out.push({ text: I18n.tr("Copy"), glyph: "content_copy", keys: "Ctrl+C", run: () => root.copy(pane) })
            if (one && one.dir) out.push({ text: I18n.tr("Paste into folder"), glyph: "content_paste", run: () => root.paste(pane, one.path) })
            const moveTo = root.sendEntries(pane, paths, "move"), copyTo = root.sendEntries(pane, paths, "copy")
            out.push({ text: I18n.tr("Move to"), glyph: "drive_file_move", enabled: writable && moveTo.length > 0, sub: moveTo })
            out.push({ text: I18n.tr("Copy to"), glyph: "folder_copy", enabled: copyTo.length > 0, sub: copyTo })
            out.push({ text: I18n.tr("Duplicate"), glyph: "file_copy", keys: "Ctrl+D", enabled: writable, run: () => root.duplicate(pane) })
            out.push({ text: I18n.tr("Make link"), glyph: "link", enabled: writable && f.mode === "folder", run: () => root.link(pane) })
            out.push({ separator: true })
            out.push({ text: list.length > 1 ? I18n.tr("Rename all…") : I18n.tr("Rename"), glyph: "edit", keys: "F2", enabled: writable, run: () => root.rename(pane) })
            out.push({ text: I18n.tr("Compress…"), glyph: "folder_zip", enabled: root.here(pane).length > 0, run: () => root.compress(pane) })
            if (archives.length > 0) out.push({ text: I18n.tr("Extract here"), glyph: "unarchive", enabled: root.here(pane).length > 0 && f.writable, run: () => root.extract(pane, "") })
            out.push({ separator: true })
            out.push({ text: I18n.tr("Copy path"), glyph: "link", keys: "Ctrl+Shift+C", run: () => root.copyText(paths.join("\n")) })
            if (one && one.dir) {
                out.push({ text: I18n.tr("Open in terminal"), glyph: "terminal", run: () => root.terminal(one.path) })
                out.push({ text: I18n.tr("Add to bookmarks"), glyph: "bookmark_add", run: () => root.bookmark(one.path) })
            }
            out.push({ separator: true })
            out.push({ text: I18n.tr("Move to trash"), glyph: "delete", keys: "Delete", enabled: writable, run: () => root.trash(pane) })
            out.push({ text: I18n.tr("Delete forever"), glyph: "delete_forever", keys: "Shift+Delete", danger: true, enabled: writable, run: () => root.deleteForever(pane) })
            out.push({ separator: true })
            out.push({ text: I18n.tr("Properties"), glyph: "info", keys: "Alt+Enter", run: () => root.propertiesOf(paths) })
            root.menus.open(out, x, y)
        })
    }
    function placeMenu(path: string, x: real, y: real): void {
        const real = !path.endsWith(":")
        root.menus.open([
            { text: I18n.tr("Open in new tab"), glyph: "tab", run: () => root.browser.newTab(path) },
            { text: I18n.tr("Open in new window"), glyph: "open_in_browser", run: () => root.browser.newWindow(path) },
            real ? { text: I18n.tr("Open in terminal"), glyph: "terminal", run: () => root.terminal(path) } : null,
            real ? { separator: true } : null,
            real ? { text: I18n.tr("Copy path"), glyph: "content_copy", run: () => root.copyText(path) } : null,
            real ? { text: I18n.tr("Add to bookmarks"), glyph: "bookmark_add", run: () => root.bookmark(path) } : null,
            real ? { text: I18n.tr("Properties"), glyph: "info", run: () => root.propertiesOf([path]) } : null
        ], x, y)
    }

    // ---- what the core reports back to this window
    function mine(id: int): bool {
        const n = Core.jobNotes[id]
        return n && n.owner ? n.owner === root.browser : root.browser.windowActive
    }
    Connections {
        target: Core
        function onConflict(q) { if (root.mine(q.job)) root.sheet(conflictSheet, { question: q }) }
        function onFailed(op, error) { if (root.browser.windowActive) root.fail(error) }
        function onJobEvent(j) {
            if (j.state !== "done" && j.state !== "failed") return
            const note = Core.jobNotes[j.job]
            if (!root.mine(j.job)) return
            const errors = j.errors ?? []
            if (j.kind === "extract" && errors.some(e => e.error === "password")) {
                const args = note ? note.args : null
                if (args) root.sheet(passwordSheet, { paths: args.paths, dest: args.dest, retry: !!args.password })
                return
            }
            if ((j.untrashable ?? []).length > 0) {
                const left = j.untrashable
                root.sheet(confirmSheet, {
                    title: I18n.n("%1 item cannot go to the trash", "%1 items cannot go to the trash", left.length),
                    subtitle: I18n.tr("The disk has no trash. Delete forever instead?"),
                    choices: [{ text: I18n.tr("Delete"), kind: "danger", run: () => Core.job("delete", { paths: left }, { owner: root.browser, undoable: false }) }]
                })
            }
            if (errors.length > 0) {
                const first = errors[0]
                Toast.fail(errors.length === 1 ? Fmt.name(first.path) + ": " + Errors.text(first.error) : I18n.n("%1 item failed", "%1 items failed", errors.length) + " · " + Errors.text(first.error))
                return
            }
            if (j.state === "done" && note && note.say) {
                // Undo files its step on the same event; the toast offers it once that has run.
                Qt.callLater(() => Toast.show(note.say, note.undoable !== false && Undo.can ? I18n.tr("Undo") : "", note.undoable !== false ? () => root.undo() : null))
            }
        }
    }

    Component { id: confirmSheet; ConfirmSheet {} }
    Component { id: conflictSheet; ConflictSheet {} }
    Component { id: propertiesSheet; PropertiesSheet { browser: root.browser } }
    Component { id: renameSheet; RenameSheet {} }
    Component { id: appsSheet; AppsSheet {} }
    Component { id: compressSheet; CompressSheet { ops: root } }
    Component { id: passwordSheet; PasswordSheet { ops: root } }
    Component { id: selectSheet; SelectSheet {} }
    Component { id: connectSheet; ConnectSheet { ops: root } }
    Component { id: settingsSheet; SettingsSheet {} }
}
