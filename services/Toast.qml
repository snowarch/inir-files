pragma Singleton
import QtQuick
import Quickshell

// One short line at the foot of the window: what just happened, with the action that takes it back.
Singleton {
    id: root

    property string text: ""
    property string action: ""
    property var run: null
    property bool error: false
    property int serial: 0

    function show(text: string, action: string, run: var): void {
        root.text = text
        root.action = action ?? ""
        root.run = run ?? null
        root.error = false
        root.serial++
    }
    function fail(text: string): void {
        root.show(text, "", null)
        root.error = true
    }
    function dismiss(): void { root.text = "" }
    function act(): void {
        const f = root.run
        root.dismiss()
        if (f) f()
    }
}
