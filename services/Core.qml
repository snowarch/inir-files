pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The bridge to inir-files-core, the process that does the file work: one JSON line per request, one per reply,
// events for what streams. A request made before the core is up waits in line; a core that dies is started again and
// the callers still waiting hear "core".
Singleton {
    id: root

    readonly property string binary: Quickshell.env("INIR_FILES_CORE") || Quickshell.shellPath("core/target/release/inir-files-core")
    readonly property string home: Quickshell.env("HOME") ?? "/"
    property bool ready: false
    property bool adminActive: false
    property bool localSendRunning: false
    property string localSendAlias: ""
    property int localSendPort: 0
    property string localSendSaveDir: ""
    property var localSendPeers: []
    property var localSendTransfers: ({})
    property bool localSendScanning: false
    property var places: ({ home: root.home, xdg: [], bookmarks: [], devices: [], network: [], trash: 0 })
    // Jobs at work and just finished, by id: the last event of each.
    property var jobs: ({})
    property var jobNotes: ({})

    property int nextId: 1
    property var waiting: ({})
    property var queue: []
    property int crashes: 0

    signal counts(string path, var counts)
    signal changed(var paths)
    signal jobEvent(var job)
    signal conflict(var question)
    signal searchBatch(var batch)
    signal sizeEvent(var data)
    signal spaceMapEvent(var data)
    signal checksumEvent(var data)
    signal failed(string op, string error)
    // A server being connected wants an answer (a password, a choice): { token, kind, message, fields, choices }.
    signal asked(var ask)
    // "Show in folder" from another app (org.freedesktop.FileManager1): how is "items", "folders" or "properties".
    signal showRequested(string how, var paths)
    // XDG Desktop Portal FileChooser request (Discord, Firefox, Chrome, etc.).
    signal chooserRequested(var req)
    signal chooserCancelled(string token)
    // LocalSend v2.1 incoming offer & transfer updates.
    signal localSendOffer(var offer)
    signal localSendTransferEvent(var transfer)

    function call(op: string, args: var, done: var): int {
        const id = root.nextId++
        const msg = Object.assign({ id: id, op: op }, args ?? {})
        if (done) {
            const w = Object.assign({}, root.waiting)
            w[id] = done
            root.waiting = w
        }
        const line = JSON.stringify(msg) + "\n"
        if (root.ready) proc.write(line)
        else root.queue = root.queue.concat([line])
        return id
    }

    // A job with what the interface needs to say about it and undo it.
    function job(op: string, args: var, note: var): void {
        root.call(op, args, reply => {
            if (!reply.ok) { root.failed(op, reply.error); return }
            const notes = Object.assign({}, root.jobNotes)
            notes[reply.job] = Object.assign({ op: op, args: args, undoable: true }, note ?? {})
            root.jobNotes = notes
        })
    }
    function cancelJob(id: int): void { root.call("job_cancel", { job: id }) }
    function answer(id: int, action: string, all: bool): void { root.call("job_answer", { job: id, action: action, all: all }) }
    function startAdmin(done: var): void {
        if (root.adminActive) { if (done) done({ ok: true, active: true }); return }
        root.call("admin_start", {}, r => {
            if (r.ok && r.active) root.adminActive = true
            if (done) done(r)
        })
    }
    function stopAdmin(done: var): void {
        root.call("admin_stop", {}, r => {
            root.adminActive = false
            if (done) done(r)
        })
    }
    function applyLocalSendStatus(s: var): void {
        if (!s) return
        root.localSendRunning = s.running === true
        root.localSendAlias = s.alias ?? ""
        root.localSendPort = Number(s.port ?? 0)
        if (s.saveDir) root.localSendSaveDir = s.saveDir
        if (s.peers) root.localSendPeers = s.peers
    }
    function syncLocalSend(): void {
        if (!root.ready) return
        root.call("localsend_config", {
            autoAccept: Prefs.localsendAutoAccept === true,
            alias: Prefs.localsendAlias ?? ""
        }, r => {
            if (r.ok) root.applyLocalSendStatus(r)
            if (Prefs.localsend === true) {
                root.call("localsend_start", {}, s => { if (s.ok) root.applyLocalSendStatus(s) })
            } else if (root.localSendRunning) {
                root.call("localsend_stop", {}, s => { if (s.ok) root.applyLocalSendStatus(s) })
            }
        })
    }
    function scanLocalSend(): void {
        if (!root.ready) return
        root.localSendScanning = true
        root.call("localsend_scan", {}, r => { if (!r.ok) root.localSendScanning = false })
    }
    function forgetLocalSendTransfer(id: string): void {
        const m = Object.assign({}, root.localSendTransfers)
        delete m[id]
        root.localSendTransfers = m
    }
    Connections {
        target: Prefs
        function onLocalsendChanged() { root.syncLocalSend() }
        function onLocalsendAutoAcceptChanged() {
            if (root.ready) root.call("localsend_config", { autoAccept: Prefs.localsendAutoAccept === true }, r => { if (r.ok) root.applyLocalSendStatus(r) })
        }
        function onLocalsendAliasChanged() {
            if (root.ready) root.call("localsend_config", { alias: Prefs.localsendAlias ?? "" }, r => { if (r.ok) root.applyLocalSendStatus(r) })
        }
    }
    function forgetJob(id: int): void {
        const j = Object.assign({}, root.jobs)
        delete j[id]
        root.jobs = j
        if (root.jobNotes[id] !== undefined) {
            const notes = Object.assign({}, root.jobNotes)
            delete notes[id]
            root.jobNotes = notes
        }
    }
    // Lightweight LRU cache of recent folder listings (metadata only, <=1500 entries, max 16 folders) for instant Back/Forward.
    // Always revalidated silently on disk; invalidated on inotify changed events or completed jobs.
    property var folderCache: ({})
    property var folderCacheOrder: []
    function listCacheKey(path: string, hidden: bool, sort: string, desc: bool, dirsFirst: bool): string {
        return path + "|" + (hidden ? "1" : "0") + "|" + sort + "|" + (desc ? "1" : "0") + "|" + (dirsFirst ? "1" : "0")
    }
    function cachedList(path: string, hidden: bool, sort: string, desc: bool, dirsFirst: bool): var {
        const key = root.listCacheKey(path, hidden, sort, desc, dirsFirst)
        const hit = root.folderCache[key]
        if (!hit) return null
        const idx = root.folderCacheOrder.indexOf(key)
        if (idx >= 0) {
            root.folderCacheOrder.splice(idx, 1)
            root.folderCacheOrder.push(key)
        }
        return hit
    }
    function rememberList(path: string, hidden: bool, sort: string, desc: bool, dirsFirst: bool, reply: var): void {
        if (!reply || !reply.ok || !reply.entries || reply.entries.length > 1500) return
        const key = root.listCacheKey(path, hidden, sort, desc, dirsFirst)
        root.folderCache[key] = reply
        const idx = root.folderCacheOrder.indexOf(key)
        if (idx >= 0) root.folderCacheOrder.splice(idx, 1)
        root.folderCacheOrder.push(key)
        while (root.folderCacheOrder.length > 16) {
            const drop = root.folderCacheOrder.shift()
            delete root.folderCache[drop]
        }
    }
    function dropListCache(paths: var): void {
        if (!paths) { root.folderCache = ({}); root.folderCacheOrder = []; return }
        for (const p of paths) {
            const prefix = p + "|"
            for (let i = root.folderCacheOrder.length - 1; i >= 0; i--) {
                if (root.folderCacheOrder[i].startsWith(prefix)) {
                    delete root.folderCache[root.folderCacheOrder[i]]
                    root.folderCacheOrder.splice(i, 1)
                }
            }
        }
    }
    // Folders on screen in any window, counted: the core watches each while one pane still shows it.
    property var watchCount: ({})
    function holdWatch(path: string): void {
        if (path.length === 0) return
        const m = Object.assign({}, root.watchCount)
        m[path] = (m[path] ?? 0) + 1
        root.watchCount = m
        watchSync.restart()
    }
    function dropWatch(path: string): void {
        if (path.length === 0 || root.watchCount[path] === undefined) return
        const m = Object.assign({}, root.watchCount)
        if (--m[path] <= 0) delete m[path]
        root.watchCount = m
        watchSync.restart()
    }
    Timer { id: watchSync; interval: 50; onTriggered: root.call("watch", { paths: Object.keys(root.watchCount) }) }

    // Files cut in any window wait here for the next paste, which moves them.
    property var cutPaths: ({})
    property int clipRev: 0
    function setCut(paths: var): void {
        const m = {}
        for (const p of paths) m[p] = true
        root.cutPaths = m
        root.clipRev++
    }

    // The bookmarks a bookmark op sends back, put in place with no new look at the disks.
    function takeBookmarks(r: var): void { if (r?.ok && r.bookmarks) root.places = Object.assign({}, root.places, { bookmarks: r.bookmarks }) }
    function refreshPlaces(): void { root.call("places", {}, r => { if (r.ok) root.places = r }) }

    // ---- thumbnails: asked for by what is on screen, answered to the item that asked
    property var thumbs: ({})
    property var thumbOrder: []
    property var thumbWaiters: ({})
    property var thumbAsk: ({})
    function thumbKey(path: string, size: string, mtime: real): string { return path + "|" + size + "|" + mtime }
    // The freedesktop size a picture drawn px device pixels wide is read from. A picture cut to fill a square needs its
    // short side to cover it: a 3:2 photo's long side is half as long again.
    function thumbSize(px: real, crop: var): string {
        const p = crop === true ? px * 1.5 : px
        return p <= 128 ? "normal" : p <= 256 ? "large" : p <= 512 ? "x-large" : "xx-large"
    }
    // Whether the settings let an entry have pictures at all: never, or only on this computer.
    function thumbsOn(e: var): bool {
        const mode = Prefs.get("thumbnails")
        return !!e && mode !== "never" && !(mode === "local" && e.remote === true)
    }
    // Whether an entry gets a picture of its own: one can be made, and it is not past the size limit.
    function wantsThumb(e: var): bool {
        return root.thumbsOn(e) && e.thumb === true && !e.dir
            && !(["image", "pdf"].includes(e.kind) && e.size > Number(Prefs.get("thumbLimit")) * 1000000)
    }
    // The picture for path at size: its file ("" when none can be had) once known, else null; the answer then goes to
    // item's thumbFile.
    function thumb(path: string, size: string, mtime: real, item: var): var {
        const key = root.thumbKey(path, size, mtime)
        if (root.thumbs[key] !== undefined) return root.thumbs[key]
        const list = root.thumbWaiters[key] ?? []
        if (list.indexOf(item) < 0) list.push(item)
        root.thumbWaiters[key] = list
        if (!root.thumbAsk[size]) root.thumbAsk[size] = []
        if (list.length === 1) root.thumbAsk[size].push(path + "\n" + mtime)
        // Started, not restarted: a scroll that keeps making cells still sends its asks every few frames.
        if (!thumbFlush.running) thumbFlush.start()
        return null
    }
    // The next few screens of a folder, made before they are scrolled to; replaces stale prefetch from prior folders.
    function thumbAhead(list: var, size: string): void {
        const paths = []
        for (const e of list) {
            if (paths.length >= 160) break
            if (!root.wantsThumb(e)) continue
            if (root.thumbs[root.thumbKey(e.path, size, e.mtime)] !== undefined) continue
            root.thumbMtimes[e.path + "|" + size] = e.mtime
            paths.push(e.path)
        }
        if (paths.length > 0) root.call("thumb", { paths: paths, size: size, ahead: true, replaceAhead: true })
    }
    function unthumb(path: string, size: string, mtime: real, item: var): void {
        const key = root.thumbKey(path, size, mtime)
        const list = root.thumbWaiters[key]
        if (!list) return
        const at = list.indexOf(item)
        if (at >= 0) list.splice(at, 1)
        if (list.length === 0) delete root.thumbWaiters[key]
    }
    property var thumbMtimes: ({})
    Timer {
        id: thumbFlush
        interval: 16
        onTriggered: {
            for (const size in root.thumbAsk) {
                const asks = root.thumbAsk[size]
                if (asks.length === 0) continue
                const paths = []
                for (let i = asks.length - 1; i >= 0; i--) {
                    const [p, m] = asks[i].split("\n")
                    root.thumbMtimes[p + "|" + size] = Number(m)
                    // The core works newest first: the top of the screen is asked for last.
                    paths.push(p)
                }
                root.call("thumb", { paths: paths, size: size })
            }
            root.thumbAsk = ({})
        }
    }
    function gotThumb(m: var): void {
        const mkey = m.path + "|" + m.size
        const mtime = root.thumbMtimes[mkey] ?? 0
        const key = root.thumbKey(m.path, m.size, mtime)
        if (root.thumbs[key] === undefined) {
            root.thumbOrder.push(key)
            if (root.thumbOrder.length > 2000) {
                const drop = root.thumbOrder.splice(0, 400)
                for (let i = 0; i < drop.length; i++) delete root.thumbs[drop[i]]
                root.thumbMtimes = ({})
            }
        }
        root.thumbs[key] = m.file
        const list = root.thumbWaiters[key]
        if (!list) return
        delete root.thumbWaiters[key]
        for (const item of list) {
            try { if (item && item.path === m.path) { item.thumbFile = m.file; item.thumbSettled = true } } catch (e) {}
        }
    }

    function line(data: string): void {
        let m
        try { m = JSON.parse(data) } catch (e) { return }
        if (m.id !== undefined) {
            const done = root.waiting[m.id]
            if (done) {
                delete root.waiting[m.id]
                done(m)
            }
            return
        }
        switch (m.event) {
        case "ready":
            root.ready = true
            for (const l of root.queue) proc.write(l)
            root.queue = []
            root.refreshPlaces()
            watchSync.restart()
            if (Prefs.localsend === true) root.syncLocalSend()
            break
        case "thumb": root.gotThumb(m); break
        case "counts": root.counts(m.path, m.counts); break
        case "changed":
            root.dropListCache(m.paths)
            root.changed(m.paths)
            break
        case "job": {
            const j = Object.assign({}, root.jobs)
            j[m.job] = m
            root.jobs = j
            if (m.state === "done" || m.state === "failed" || m.state === "cancelled") root.dropListCache(null)
            root.jobEvent(m)
            break
        }
        case "conflict": root.conflict(m); break
        case "search": root.searchBatch(m); break
        case "dirsize": root.sizeEvent(m); break
        case "space_map": root.spaceMapEvent(m); break
        case "checksum": root.checksumEvent(m); break
        case "places": root.places = m; break
        case "ask": root.asked(m); break
        case "show": root.showRequested(m.how, m.paths ?? []); break
        case "chooser": root.chooserRequested(m); break
        case "chooser_cancel": root.chooserCancelled(m.token ?? ""); break
        case "admin": root.adminActive = m.active === true; break
        case "localsend_status": root.applyLocalSendStatus(m); break
        case "localsend_peers": root.localSendPeers = m.peers ?? []; break
        case "localsend_scan":
            root.localSendScanning = false
            if (m.peers) root.localSendPeers = m.peers
            break
        case "localsend_offer": root.localSendOffer(m); break
        case "localsend_transfer": {
            const t = Object.assign({}, root.localSendTransfers)
            t[m.id] = m
            root.localSendTransfers = t
            root.localSendTransferEvent(m)
            break
        }
        }
    }

    Process {
        id: proc
        command: [root.binary]
        running: true
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => root.line(data)
        }
        onExited: (code, status) => {
            root.ready = false
            root.adminActive = false
            const w = root.waiting
            root.waiting = ({})
            for (const id in w) w[id]({ id: Number(id), ok: false, error: "core" })
            root.crashes++
            if (root.crashes < 6) restart.start()
            else console.warn("[inir-files] the core keeps stopping: " + root.binary)
        }
    }
    Timer { id: restart; interval: 400; onTriggered: proc.running = true }
    Timer { interval: 60000; running: root.crashes > 0; repeat: true; onTriggered: root.crashes = 0 }
}
