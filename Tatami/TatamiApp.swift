import SwiftUI

/// Tatami のエントリポイント。ウィンドウ管理 (#4) の実装までは、ウィンドウ 1 つに BrowserWindowView を置く
@main
struct TatamiApp: App {
    var body: some Scene {
        WindowGroup("Tatami") {
            BrowserWindowView()
        }
        .commands {
            PaneCommands()
        }
    }
}
