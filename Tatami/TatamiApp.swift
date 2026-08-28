import SwiftUI

/// Tatami のエントリポイント。ペインツリー実装前の最小構成として、ウィンドウ 1 つに BrowserWindowView を置く
@main
struct TatamiApp: App {
    var body: some Scene {
        WindowGroup("Tatami") {
            BrowserWindowView()
        }
    }
}
