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
/// ショートカットはブラウザで慣習的な ⌘ 系 (閉じる ⌘W・戻る ⌘[ 等) と衝突しないものを選んだ (Window は macOS のウィンドウではなく tmux の window)。
/// accessibilityIdentifier は WebDriverAgentMac から表示名に依存せず項目を特定するために付ける (tmux のコマンド名に倣う)
struct PaneCommands: Commands {
    @FocusedValue(\.browserWindowModel) private var model

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Open Location") { model?.perform(command: .omnibox) }
                .keyboardShortcut("l", modifiers: [.command])
                .accessibilityIdentifier("menu-omnibox")
            Button("Back") { model?.perform(command: .goBack) }
                .keyboardShortcut("[", modifiers: [.command])
                .accessibilityIdentifier("menu-back")
            Button("Forward") { model?.perform(command: .goForward) }
                .keyboardShortcut("]", modifiers: [.command])
                .accessibilityIdentifier("menu-forward")
            Button("Reload") { model?.perform(command: .reload) }
                .keyboardShortcut("r", modifiers: [.command])
                .accessibilityIdentifier("menu-reload")
        }
        CommandMenu("Pane") {
            Button("Split Left / Right") { model?.perform(command: .splitWindowHorizontal) }
                .keyboardShortcut("d", modifiers: [.command])
                .accessibilityIdentifier("menu-split-window-h")
            Button("Split Top / Bottom") { model?.perform(command: .splitWindowVertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .accessibilityIdentifier("menu-split-window-v")
            Button("Close Pane") { model?.perform(command: .killPane) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .accessibilityIdentifier("menu-kill-pane")
            Divider()
            Button("Next Pane") { model?.perform(command: .selectPaneNext) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-select-pane-next")
            Button("Previous Pane") { model?.currentWindow.focusPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-select-pane-previous")
            Button("Last Pane") { model?.perform(command: .selectPaneLast) }
                .keyboardShortcut(";", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-last-pane")
            Divider()
            Button("Zoom Pane") { model?.perform(command: .resizePaneZoom) }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-resize-pane-zoom")
            Button("Next Layout") { model?.perform(command: .nextLayout) }
                .keyboardShortcut(" ", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-next-layout")
            Button("Swap With Previous") { model?.perform(command: .swapPaneUp) }
                .keyboardShortcut("{", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-swap-pane-up")
            Button("Swap With Next") { model?.perform(command: .swapPaneDown) }
                .keyboardShortcut("}", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-swap-pane-down")
            Divider()
            Button("New Window") { model?.perform(command: .newWindow) }
                .keyboardShortcut("t", modifiers: [.command])
                .accessibilityIdentifier("menu-new-window")
            Button("Next Window") { model?.perform(command: .nextWindow) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .accessibilityIdentifier("menu-next-window")
            Button("Previous Window") { model?.perform(command: .previousWindow) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .accessibilityIdentifier("menu-previous-window")
            Button("Rename Window…") { model?.perform(command: .renameWindow) }
                .accessibilityIdentifier("menu-rename-window")
            Button("Choose Window…") { model?.perform(command: .chooseWindow) }
                .accessibilityIdentifier("menu-choose-window")
            Button("Close Window") { model?.perform(command: .killWindow) }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-kill-window")
        }
    }
}
