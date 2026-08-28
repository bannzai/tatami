import SwiftUI

/// メニューのペイン操作の宛先。キーウィンドウの BrowserWindowView が自分のモデルを供給する
struct BrowserWindowModelKey: FocusedValueKey {
    typealias Value = BrowserWindowModel
}

extension FocusedValues {
    var browserWindowModel: BrowserWindowModel? {
        get { self[BrowserWindowModelKey.self] }
        set { self[BrowserWindowModelKey.self] = newValue }
    }
}

/// ペインと tmux window の操作メニュー。prefix キーと同じコマンドをマウス操作からも呼べるようにする。
/// ショートカットはブラウザで慣習的な ⌘ 系 (閉じる ⌘W・戻る ⌘[ 等) と衝突しないものを選んだ (Window は macOS のウィンドウではなく tmux の window)
struct PaneCommands: Commands {
    @FocusedValue(\.browserWindowModel) private var model

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Open Location") { model?.perform(command: .omnibox) }
                .keyboardShortcut("l", modifiers: [.command])
            Button("Back") { model?.perform(command: .goBack) }
                .keyboardShortcut("[", modifiers: [.command])
            Button("Forward") { model?.perform(command: .goForward) }
                .keyboardShortcut("]", modifiers: [.command])
            Button("Reload") { model?.perform(command: .reload) }
                .keyboardShortcut("r", modifiers: [.command])
        }
        CommandMenu("Pane") {
            Button("Split Left / Right") { model?.perform(command: .splitWindowHorizontal) }
                .keyboardShortcut("d", modifiers: [.command])
            Button("Split Top / Bottom") { model?.perform(command: .splitWindowVertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Close Pane") { model?.perform(command: .killPane) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Next Pane") { model?.perform(command: .selectPaneNext) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Previous Pane") { model?.currentWindow.focusPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Last Pane") { model?.perform(command: .selectPaneLast) }
                .keyboardShortcut(";", modifiers: [.command, .option])
            Divider()
            Button("Zoom Pane") { model?.perform(command: .resizePaneZoom) }
                .keyboardShortcut("z", modifiers: [.command, .option])
            Button("Next Layout") { model?.perform(command: .nextLayout) }
                .keyboardShortcut(" ", modifiers: [.command, .option])
            Button("Swap With Previous") { model?.perform(command: .swapPaneUp) }
                .keyboardShortcut("{", modifiers: [.command, .option])
            Button("Swap With Next") { model?.perform(command: .swapPaneDown) }
                .keyboardShortcut("}", modifiers: [.command, .option])
            Divider()
            Button("New Window") { model?.perform(command: .newWindow) }
                .keyboardShortcut("t", modifiers: [.command])
            Button("Next Window") { model?.perform(command: .nextWindow) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Window") { model?.perform(command: .previousWindow) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Rename Window…") { model?.perform(command: .renameWindow) }
            Button("Choose Window…") { model?.perform(command: .chooseWindow) }
            Button("Close Window") { model?.perform(command: .killWindow) }
                .keyboardShortcut("w", modifiers: [.command, .option])
        }
    }
}
