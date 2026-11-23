import QtQuick
import org.kde.syntaxhighlighting
import qs.services

// Source text in the colours of its language, read only.
TextEdit {
    id: root
    property string fileName: ""
    readOnly: true
    selectByMouse: true
    textFormat: TextEdit.PlainText
    wrapMode: TextEdit.NoWrap
    color: Theme.ink
    selectionColor: Theme.alpha(Theme.accent, 0.4)
    selectedTextColor: Theme.ink
    font.family: Theme.mono
    font.pixelSize: Theme.small
    renderType: TextEdit.NativeRendering
    font.hintingPreference: Font.PreferDefaultHinting
    SyntaxHighlighter {
        textEdit: root
        definition: Repository.definitionForFileName(root.fileName)
        theme: Repository.defaultTheme(Theme.light ? Repository.LightTheme : Repository.DarkTheme)
    }
}
