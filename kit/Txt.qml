import QtQuick
import qs.services

// Text in the app's sans, sentence case. Drawn by the system's rasteriser with its hinting, as the shell draws its
// own: on a 1x screen the default distance-field text is soft at these sizes.
Text {
    property real size: Theme.body
    property bool strong: false
    color: Theme.ink
    font.family: Theme.sans
    renderType: Text.NativeRendering
    font.hintingPreference: Font.PreferDefaultHinting
    font.pixelSize: Math.round(size)
    font.weight: strong ? Font.DemiBold : Font.Normal
    elide: Text.ElideRight
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
}
