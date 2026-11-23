import QtQuick
import qs.services

// A Material Symbol, its weight matched to the text beside it.
Text {
    id: root
    property string name: ""
    property real size: Theme.dp(18)
    property real fill: 0
    property int weight: 400
    text: root.name
    color: Theme.ink
    width: root.size
    height: root.size
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    renderType: Text.NativeRendering
    font.family: Theme.glyphs
    font.pixelSize: root.size
    font.hintingPreference: Font.PreferNoHinting
    font.variableAxes: ({ "FILL": root.fill, "wght": root.weight, "opsz": Math.max(20, Math.min(48, root.size)), "GRAD": 0 })
}
