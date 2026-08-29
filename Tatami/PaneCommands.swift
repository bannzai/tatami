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

/// ペイン操作のメニュー。prefix キー (#3) の実装までの操作手段で、実装後もメニューからの操作として残す。
/// ショートカットはブラウザで慣習的な ⌘ 系 (閉じる ⌘W・戻る ⌘[ 等) と衝突しないものを選んだ。
/// accessibilityIdentifier は WebDriverAgentMac から表示名に依存せず項目を特定するために付ける (tmux のコマンド名に倣う)
struct PaneCommands: Commands {
    @FocusedValue(\.browserWindowModel) private var model

    var body: some Commands {
        CommandMenu("Pane") {
            Button("Split Left / Right") { model?.split(axis: .horizontal) }
                .keyboardShortcut("d", modifiers: [.command])
                .accessibilityIdentifier("menu-split-window-h")
            Button("Split Top / Bottom") { model?.split(axis: .vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .accessibilityIdentifier("menu-split-window-v")
            Button("Close Pane") { model?.closeFocusedPane() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .accessibilityIdentifier("menu-kill-pane")
            Divider()
            Button("Next Pane") { model?.focusNext() }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-select-pane-next")
            Button("Previous Pane") { model?.focusPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-select-pane-previous")
            Button("Last Pane") { model?.focusLastPane() }
                .keyboardShortcut(";", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-last-pane")
            Divider()
            Button("Zoom Pane") { model?.toggleZoom() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-resize-pane-zoom")
            Button("Next Layout") { model?.applyNextLayout() }
                .keyboardShortcut(" ", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-next-layout")
            Button("Swap With Previous") { model?.swapWithPrevious() }
                .keyboardShortcut("{", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-swap-pane-up")
            Button("Swap With Next") { model?.swapWithNext() }
                .keyboardShortcut("}", modifiers: [.command, .option])
                .accessibilityIdentifier("menu-swap-pane-down")
        }
    }
}
