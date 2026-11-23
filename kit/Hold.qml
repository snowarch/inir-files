import QtQuick

// A finger or a pen held still on a thing gives its menu, as a right click does. A held mouse button only waits to drag,
// so its click stays a click. `fired` tells the click that ends a hold to pass; a mouse press clears it.
TapHandler {
    id: root
    property bool fired: false
    signal held(point at)
    acceptedDevices: PointerDevice.TouchScreen | PointerDevice.Stylus
    gesturePolicy: TapHandler.DragThreshold
    onPressedChanged: if (pressed) root.fired = false
    onLongPressed: {
        root.fired = true
        root.held(root.point.position)
    }
}
