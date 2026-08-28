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
/// ショートカットはブラウザで慣習的な ⌘ 系 (閉じる ⌘W・戻る ⌘[ 等) と衝突しないものを選んだ
struct PaneCommands: Commands {
    @FocusedValue(\.browserWindowModel) private var model

    var body: some Commands {
        CommandMenu("Pane") {
            Button("Split Left / Right") { model?.split(axis: .horizontal) }
                .keyboardShortcut("d", modifiers: [.command])
            Button("Split Top / Bottom") { model?.split(axis: .vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Close Pane") { model?.closeFocusedPane() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Next Pane") { model?.focusNext() }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Previous Pane") { model?.focusPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Last Pane") { model?.focusLastPane() }
                .keyboardShortcut(";", modifiers: [.command, .option])
            Divider()
            Button("Zoom Pane") { model?.toggleZoom() }
                .keyboardShortcut("z", modifiers: [.command, .option])
            Button("Next Layout") { model?.applyNextLayout() }
                .keyboardShortcut(" ", modifiers: [.command, .option])
            Button("Swap With Previous") { model?.swapWithPrevious() }
                .keyboardShortcut("{", modifiers: [.command, .option])
            Button("Swap With Next") { model?.swapWithNext() }
                .keyboardShortcut("}", modifiers: [.command, .option])
        }
    }
}
