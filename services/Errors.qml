pragma Singleton
import QtQuick
import Quickshell

// The core's error codes in words.
Singleton {
    function text(code: string): string {
        switch (code) {
        case "missing": return I18n.tr("It no longer exists")
        case "denied": return I18n.tr("Permission denied")
        case "notdir": return I18n.tr("It is not a folder")
        case "exists": return I18n.tr("That name is taken")
        case "notempty": return I18n.tr("The folder is not empty")
        case "readonly": return I18n.tr("The disk is read only")
        case "full": return I18n.tr("The disk is full")
        case "crossdevice": return I18n.tr("It cannot move across disks this way")
        case "badname": return I18n.tr("That name cannot be used")
        case "password": return I18n.tr("The archive needs a password")
        case "noapp": return I18n.tr("No application opens this kind of file")
        case "noterminal": return I18n.tr("No terminal was found")
        case "noinir": return I18n.tr("iNiR is not running")
        case "busy": return I18n.tr("The disk is in use")
        case "intoitself": return I18n.tr("A folder cannot go inside itself")
        case "core": return I18n.tr("The file service stopped; try again")
        case "norg": return I18n.tr("Searching inside files needs ripgrep")
        case "empty": return I18n.tr("The clipboard is empty")
        default: return code && code.length > 0 ? code : I18n.tr("Something went wrong")
        }
    }
}
