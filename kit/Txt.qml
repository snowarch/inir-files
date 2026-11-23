import QtQuick
import qs.services

// Text in the app's sans, sentence case.
Text {
    property real size: Theme.body
    property bool strong: false
    color: Theme.ink
    font.family: Theme.sans
    font.pixelSize: size
    font.weight: strong ? Font.DemiBold : Font.Normal
    elide: Text.ElideRight
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
}
