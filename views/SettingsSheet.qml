import QtQuick
import QtQuick.Controls.Basic as QQC
import qs.services
import qs.kit

// The few choices the app leaves open. Each one takes effect at once.
Sheet {
    id: root
    cardWidth: Theme.dp(560)
    title: I18n.tr("Settings")

    component Setting: Item {
        id: s
        property string label: ""
        property string hint: ""
        default property alias control: slot.data
        width: parent ? parent.width : 0
        height: Math.max(Theme.dp(44), words.implicitHeight + Theme.dp(12))
        Column {
            id: words
            anchors.left: parent.left
            anchors.right: slot.left
            anchors.rightMargin: Theme.dp(14)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(1)
            Txt { width: parent.width; text: s.label; size: Theme.body }
            Txt { width: parent.width; visible: s.hint.length > 0; text: s.hint; size: Theme.small; color: Theme.ink3; wrapMode: Text.Wrap; elide: Text.ElideNone }
        }
        Item {
            id: slot
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
    }
    component Switch: Toggle {
        required property string key
        checked: Prefs.get(key) === true
        onToggled: value => Prefs.set(key, value)
    }
    component Choice: Segments {
        required property string key
        value: Prefs.get(key)
        onChosen: value => Prefs.set(key, value)
    }
    component Head: Caption { topPadding: Theme.dp(10) }
    // Where more settings wait above or below, the edge fades into the card: no row looks cut.
    component Fade: Rectangle {
        property bool shown: false
        property bool down: true
        width: parent.width
        height: Theme.dp(28)
        opacity: shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
        gradient: Gradient {
            GradientStop { position: 0; color: down ? Theme.alpha(root.face, 0) : root.face }
            GradientStop { position: 1; color: down ? root.face : Theme.alpha(root.face, 0) }
        }
    }

    Item {
        width: parent.width
        height: Math.min(list.implicitHeight, root.height - Theme.dp(200))
        Flickable {
            id: flick
            anchors.fill: parent
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollBar.vertical: Scroller {}
            Column {
                id: list
                width: parent.width
                Head { text: I18n.tr("Look") }
                Setting {
                    label: I18n.tr("Light or dark")
                    Choice {
                        key: "scheme"
                        options: [
                            { value: "system", glyph: "brightness_auto", tip: I18n.tr("Like the system") },
                            { value: "light", glyph: "light_mode", tip: I18n.tr("Light") },
                            { value: "dark", glyph: "dark_mode", tip: I18n.tr("Dark") }
                        ]
                    }
                }
                Setting {
                    label: I18n.tr("Colour of the wallpaper")
                    hint: I18n.tr("How much of the desktop's colour reaches the window.")
                    Choice {
                        key: "tint"
                        options: [{ value: 0, text: I18n.tr("None") }, { value: 0.3, text: I18n.tr("Soft") }, { value: 0.55, text: I18n.tr("Medium") }, { value: 0.85, text: I18n.tr("Full") }]
                    }
                }
                Setting {
                    label: I18n.tr("Size")
                    Choice {
                        key: "density"
                        options: [{ value: 0.9, text: I18n.tr("Compact") }, { value: 1, text: I18n.tr("Regular") }, { value: 1.1, text: I18n.tr("Roomy") }]
                    }
                }
                Setting {
                    label: I18n.tr("Icons")
                    hint: I18n.tr("Drawn icons follow the accent; the system's follow the icon theme.")
                    Choice { key: "icons"; options: [{ value: "drawn", text: I18n.tr("Drawn") }, { value: "system", text: I18n.tr("System") }] }
                }
                Setting { label: I18n.tr("Motion"); Switch { key: "motion" } }

                Head { text: I18n.tr("Browsing") }
                Setting { label: I18n.tr("Open with one click"); Switch { key: "singleClick" } }
                Setting { label: I18n.tr("Typing jumps to a name"); hint: I18n.tr("Off: typing starts a search."); Switch { key: "typeAhead" } }
                Setting { label: I18n.tr("Show hidden files"); Switch { key: "hidden" } }
                Setting { label: I18n.tr("Folders first"); Switch { key: "dirsFirst" } }
                Setting { label: I18n.tr("Count what folders hold"); Switch { key: "counts" } }
                Setting { label: I18n.tr("Reopen the last tabs"); Switch { key: "restoreTabs" } }
                Setting {
                    label: I18n.tr("Previews")
                    hint: I18n.tr("Pictures, films, documents and covers drawn in place of their icons.")
                    Choice { key: "thumbnails"; options: [{ value: "all", text: I18n.tr("Everywhere") }, { value: "local", text: I18n.tr("This computer") }, { value: "never", text: I18n.tr("Never") }] }
                }
                Setting { label: I18n.tr("Pictures on folders"); hint: I18n.tr("A folder shows a picture it holds."); Switch { key: "covers" } }

                Head { text: I18n.tr("Safety") }
                Setting { label: I18n.tr("Ask before moving to the trash"); Switch { key: "confirmTrash" } }

                Head { text: I18n.tr("Terminal") }
                Setting {
                    label: I18n.tr("Terminal command")
                    hint: I18n.tr("Empty: the first terminal found.")
                    Field {
                        width: Theme.dp(200)
                        text: Prefs.get("terminal") ?? ""
                        placeholder: "kitty, foot, ghostty…"
                        onEdited: Prefs.set("terminal", text.trim())
                    }
                }
            }
        }
        Fade { anchors.top: parent.top; down: false; shown: flick.contentY > 1 }
        Fade { anchors.bottom: parent.bottom; shown: flick.contentY < flick.contentHeight - flick.height - 1 }
    }
    actions: [
        Pill { text: I18n.tr("Done"); kind: "solid"; onClicked: root.close() }
    ]
}
