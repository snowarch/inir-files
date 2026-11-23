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

    function open(path: string): void {
        root.serial++
        windows.append({ key: root.serial, path: path ?? "", first: root.serial === 1 })
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
    Component.onCompleted: root.open(Quickshell.env("INIR_FILES_OPEN") ?? "")

    ListModel { id: windows }
    Instantiator {
        model: windows
        delegate: Browser {
            required property int key
            required property string path
            required property bool first
            startPath: path
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
