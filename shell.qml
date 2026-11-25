//@ pragma UseQApplication
//@ pragma AppId inir-files
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.views

// iNiR Files. One process holds every window; "inir-files PATH" asks the running one for a new window.
ShellRoot {
    id: root
    property int serial: 0

    // A window at path; chosen: the entries to choose there; props: their properties open over it; chooser: portal req.
    function open(path: string, chosen: var, props: var, chooser: var): void {
        root.serial++
        windows.append({
            key: root.serial,
            path: path ?? "",
            chosen: JSON.stringify(chosen ?? []),
            props: props === true,
            chooserJson: chooser ? JSON.stringify(chooser) : "",
            chooserToken: chooser ? String(chooser.token ?? "") : "",
            first: root.serial === 1 && !chooser
        })
    }
    function forget(key: int): void {
        for (let i = 0; i < windows.count; i++) {
            if (windows.get(i).key === key) { windows.remove(i); break }
        }
        if (windows.count === 0) {
            Prefs.flush()
            Qt.quit()
        }
    }
    function cancelChooser(token: string): void {
        for (let i = 0; i < windows.count; i++) {
            if (windows.get(i).chooserToken === token) { windows.remove(i); break }
        }
        if (windows.count === 0 && Quickshell.env("INIR_FILES_SERVICE") !== "1") {
            Prefs.flush()
            Qt.quit()
        }
    }
    Component.onCompleted: {
        // Started by D-Bus for a call ("inir-files --service"): the call opens the window.
        if (Quickshell.env("INIR_FILES_SERVICE") === "1") idle.start()
        else root.open(Quickshell.env("INIR_FILES_OPEN") ?? "")
    }
    // A process the bus started that was asked nothing ends.
    Timer { id: idle; interval: 30000; onTriggered: if (windows.count === 0) { Prefs.flush(); Qt.quit() } }

    // Each item shows chosen in its folder, one window for each folder.
    Connections {
        target: Core
        function onShowRequested(how: string, paths: var): void {
            if (how === "folders") {
                for (const p of paths) root.open(p)
                return
            }
            const by = {}
            for (const p of paths) {
                const d = Fmt.parent(p)
                by[d] = (by[d] ?? []).concat([p])
            }
            for (const d in by) root.open(d, by[d], how === "properties")
        }
        function onChooserRequested(req: var): void {
            const dir = req.folder && req.folder.length > 0 ? req.folder : Core.home
            root.open(dir, [], false, req)
        }
        function onChooserCancelled(token: string): void {
            root.cancelChooser(token)
        }
    }

    ListModel { id: windows }
    Instantiator {
        model: windows
        delegate: Browser {
            required property int key
            required property string path
            required property bool first
            required property string chosen
            required property bool props
            required property string chooserJson
            startPath: path
            startChosen: JSON.parse(chosen)
            startProps: props
            chooser: chooserJson.length > 0 ? JSON.parse(chooserJson) : null
            restoreTabs: first
            visible: true
            onNewWindowRequested: p => root.open(p)
            onCloseRequested: root.forget(key)
            onClosed: root.forget(key)
        }
    }

    IpcHandler {
        target: "files"
        function open(path: string): void { root.open(path) }
        function newWindow(): void { root.open("") }
    }
}
