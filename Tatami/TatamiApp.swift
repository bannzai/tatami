import SwiftUI

/// Tatami のエントリポイント。ウィンドウ管理 (#4) の実装までは、ウィンドウ 1 つに BrowserWindowView を置く
@main
struct TatamiApp: App {
    var body: some Scene {
        WindowGroup("Tatami") {
            BrowserWindowView()
                // 他アプリからの URL は既存のウィンドウで受ける (新しい macOS ウィンドウを作らない)。documents/PROJECT.md 機能要件 4
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            PaneCommands()
        }
    }
}
