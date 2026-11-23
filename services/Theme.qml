pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The look. The desktop's own colours (the Material palette iNiR generates from the wallpaper) laid out as three
// columns a step apart (rail, canvas, aside), smoked toward a neutral graphite so the tint stays quiet; fields pressed
// into the surface (a darker top edge, a lit bottom one), an edge of light on what is raised, and the chosen thing as
// a solid pill in the accent. The palette is the one the shell hands to apps (app-palette.json: its scheme with the
// global style laid over it), else the scheme as generated (colors.json); both are watched, so the app follows the
// shell as it changes. With no palette on disk it falls back to the same graphite with a blue accent. Its faces, size
// scale and corners come from the shell too (app-look.json), so the window wears the family the desktop wears.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") ?? ""
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")

    property var appPal: ({})
    property var schemePal: ({})
    readonly property var pal: root.appPal.surface !== undefined ? root.appPal : root.schemePal
    property string systemMode: "dark"
    property var look: ({})

    function parse(text: string): var {
        try { return JSON.parse(text) } catch (e) { return ({}) }
    }

    // A palette half written reads as nothing: the last whole one stays until the next change.
    function take(text: string, keep: var): var {
        const p = root.parse(text)
        return p.surface !== undefined && p.primary !== undefined ? p : keep
    }
    FileView {
        path: root.stateHome + "/quickshell/user/generated/app-palette.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.appPal = root.take(text(), root.appPal)
    }
    FileView {
        path: root.stateHome + "/quickshell/user/generated/colors.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.schemePal = root.take(text(), root.schemePal)
    }
    FileView {
        path: root.stateHome + "/quickshell/user/generated/theme-meta.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.systemMode = root.parse(text()).mode === "light" ? "light" : "dark"
    }
    FileView {
        path: root.stateHome + "/quickshell/user/generated/app-look.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const l = root.parse(text())
            if (l.font !== undefined) root.look = l
        }
    }

    // ---- colour arithmetic
    function mix(a: color, b: color, t: real): color {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
    }
    function alpha(c: color, a: real): color { return Qt.rgba(c.r, c.g, c.b, a) }
    function luminance(c: color): real {
        const lin = x => x <= 0.04045 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4)
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    function contrast(a: color, b: color): real {
        const la = root.luminance(a), lb = root.luminance(b)
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
    }
    // From a share of the way toward the ink, moved on until it reads at 4.5:1 on both card and rail.
    function legible(share: real): color {
        for (let at = share; at < 1; at += 0.04) {
            const c = root.mix(root.card, root.ink, at)
            if (root.contrast(c, root.card) >= 4.5 && root.contrast(c, root.rail) >= 4.5) return c
        }
        return root.ink
    }

    // ---- scheme
    readonly property bool light: Prefs.scheme === "light" || (Prefs.scheme === "system" && root.systemMode === "light")
    // The palette is drawn for the system's mode: a forced other mode keeps only its accent.
    readonly property bool ownPalette: root.pal.surface !== undefined && root.light === (root.systemMode === "light")
    function key(name: string, darkFallback: string, lightFallback: string): color {
        return root.ownPalette && root.pal[name] ? root.pal[name] : (root.light ? lightFallback : darkFallback)
    }
    readonly property color graphite: root.light ? "#f1f2f5" : "#0f1013"
    // How far the desktop's tint reaches the ground: 0 neutral graphite, 1 the palette as it is.
    readonly property real tint: Prefs.tint
    function ground(c: color): color { return root.mix(root.graphite, c, root.tint) }

    readonly property color surface: root.ground(root.key("surface", "#131316", "#f8f9fb"))
    readonly property color high: root.ground(root.key("surface_container_high", "#22242a", "#e8e9ee"))
    readonly property color highest: root.ground(root.key("surface_container_highest", "#2c2e34", "#e1e3e8"))

    readonly property color canvas: root.light ? root.mix(root.surface, root.highest, 0.35) : root.surface
    readonly property color rail: root.light ? root.mix(root.surface, root.highest, 0.75) : root.mix(root.surface, root.high, 0.55)
    readonly property color card: root.light ? root.mix(root.surface, "#ffffff", 0.75) : root.mix(root.surface, root.high, 0.8)
    // Menus, sheets, tooltips: opaque, a step over everything.
    readonly property color raised: root.light ? "#ffffff" : root.mix(root.high, root.highest, 0.6)
    readonly property color line: root.light ? Qt.rgba(0, 0, 0, 0.08) : Qt.rgba(1, 1, 1, 0.065)
    readonly property color fill: root.light ? Qt.rgba(0, 0, 0, 0.045) : Qt.rgba(1, 1, 1, 0.055)
    readonly property color fillHover: root.light ? Qt.rgba(0, 0, 0, 0.075) : Qt.rgba(1, 1, 1, 0.09)
    readonly property color fillPress: root.light ? Qt.rgba(0, 0, 0, 0.11) : Qt.rgba(1, 1, 1, 0.13)
    // A field pressed into the surface: darker along its top edge, lit along its bottom one.
    readonly property color inset: root.light ? Qt.rgba(0, 0, 0, 0.05) : Qt.rgba(0, 0, 0, 0.22)
    readonly property color insetShadow: root.light ? Qt.rgba(0, 0, 0, 0.1) : Qt.rgba(0, 0, 0, 0.42)
    readonly property color insetLight: root.light ? Qt.rgba(1, 1, 1, 0.9) : Qt.rgba(1, 1, 1, 0.07)
    // The edge of light along the top of what is raised.
    readonly property color edge: root.light ? Qt.rgba(1, 1, 1, 0.9) : Qt.rgba(1, 1, 1, 0.075)
    readonly property color shadow: root.light ? Qt.rgba(0, 0, 0, 0.16) : Qt.rgba(0, 0, 0, 0.5)
    readonly property color scrim: root.light ? Qt.rgba(0.95, 0.95, 0.97, 0.6) : Qt.rgba(0.02, 0.02, 0.03, 0.62)

    readonly property color ink: root.key("on_surface", "#e6e7eb", "#1a1b1f")
    readonly property color ink2: root.legible(0.68)
    readonly property color ink3: root.legible(0.52)
    readonly property color inkNav: root.mix(root.rail, root.ink, 0.86)

    readonly property color accent: root.pal.primary ? (root.ownPalette ? root.pal.primary : root.toned(root.pal.primary)) : (root.light ? "#2f62c9" : "#a8c7fa")
    readonly property color inkAccent: root.ownPalette && root.pal.on_primary ? root.pal.on_primary : (root.luminance(root.accent) > 0.4 ? "#0d0e11" : "#ffffff")
    // A system accent shown in the other mode: deep on light, pale on dark.
    function toned(c: color): color {
        const k = Qt.color(c)
        return Qt.hsla(Math.max(0, k.hslHue), Math.min(k.hslSaturation, root.light ? 0.6 : 0.8), root.light ? 0.42 : 0.78, 1)
    }
    readonly property color accentInk: {
        for (let step = 0; step <= 10; step++) {
            const c = root.mix(root.ink, root.accent, 1 - step / 10)
            if (root.contrast(c, root.rail) >= 4.5 && root.contrast(c, root.canvas) >= 4.5) return c
        }
        return root.ink
    }
    readonly property color accentPlate: root.alpha(root.accent, root.light ? 0.13 : 0.16)
    // What is chosen: the accent laid thin over the ground, never solid, so a folder drawn in the accent and the text
    // on it keep their own colours. A pane not in use shows its choice in grey.
    readonly property color selection: root.alpha(root.accent, root.light ? 0.2 : 0.24)
    readonly property color selectionHover: root.alpha(root.accent, root.light ? 0.27 : 0.31)
    readonly property color secondary: root.key("secondary", "#bfc6dc", "#565e71")
    readonly property color tertiary: root.key("tertiary", "#debcdf", "#715573")
    readonly property color danger: root.light ? "#d70015" : "#ff453a"
    readonly property color warning: root.light ? "#b25000" : "#ffb340"
    readonly property color success: root.light ? "#248a3d" : "#30d158"
    // The colours a person can give a bookmark, by the name its look keeps.
    readonly property var tints: ({ accent: root.accentInk, secondary: root.secondary, tertiary: root.tertiary, red: root.danger, amber: root.warning, green: root.success })

    // Folders: the accent as two sheets, the back a step deeper, a paper between them.
    readonly property color folderFront: root.light ? root.mix(root.accent, "#ffffff", 0.42) : root.accent
    readonly property color folderBack: root.light ? root.mix(root.accent, "#ffffff", 0.18) : root.mix(root.accent, "#000000", 0.28)
    readonly property color folderMark: root.alpha(root.mix(root.folderFront, "#000000", 0.55), 0.55)
    readonly property color paper: root.light ? "#ffffff" : root.mix(root.surface, root.ink, 0.16)
    readonly property color paperFold: root.light ? root.mix("#ffffff", "#000000", 0.1) : root.mix(root.surface, root.ink, 0.28)
    // A file's kind in the desktop's own hues, nothing invented.
    function kindColor(kind: string): color {
        switch (kind) {
        case "image": case "video": return root.tertiary
        case "audio": case "archive": case "disk": return root.secondary
        case "pdf": case "document": case "app": case "executable": return root.accent
        default: return root.ink3
        }
    }

    // ---- measure: the sizes as drawn, the density on top
    readonly property real density: Prefs.density
    function dp(value: real): real { return Math.round(value * root.density) }
    // How round the shell draws its corners: 1 its standard ladder, 0 square, up to 2.
    readonly property real shape: {
        const r = Number(root.look.rounding)
        return isFinite(r) && root.look.rounding !== undefined ? Math.max(0, Math.min(2, r)) : 1
    }
    // A corner's radius: the density and the shell's shape on top. Pills and circles keep half their height.
    function round(value: real): real { return Math.round(value * root.density * root.shape) }
    readonly property real radius: root.round(12)
    readonly property real cardRadius: root.round(18)
    readonly property real corner: root.round(22)

    // ---- type
    readonly property real sizeScale: Number(root.look.sizeScale ?? 1) || 1
    readonly property string sans: root.look.font || "sans-serif"
    readonly property string title: root.look.title || root.sans
    readonly property string mono: root.look.mono || "monospace"
    readonly property string glyphs: "Material Symbols Rounded"
    // Whole pixels: a size between two is cut down to the lower one and drawn soft. The steps sit one under the shell's
    // own (15 px for its labels at 1x), so a list holds more and still reads beside it; nothing goes under 11. The
    // shell's size scale and the density sit on top.
    function type(value: real): real { return Math.max(11, Math.round(value * root.density * root.sizeScale)) }
    readonly property real caption: root.type(12)
    readonly property real small: root.type(13)
    readonly property real body: root.type(14)
    readonly property real row: root.type(15)
    readonly property real head: root.type(17)
    readonly property real titleSize: root.type(22)
    readonly property real display: root.type(30)

    // ---- motion
    readonly property bool motion: Prefs.motion
    function ms(value: real): int { return root.motion ? value : 0 }
    readonly property int fast: root.ms(160)
    readonly property int normal: root.ms(220)
    readonly property int slow: root.ms(260)
}
