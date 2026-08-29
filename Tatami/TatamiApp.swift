import AppKit
import SwiftUI

/// アプリがアクティブになるたびに自動入力候補を Keychain と揃える。ウィンドウを 1 枚も開いていない時 (BrowserWindowModel が無い) でも、
/// iCloud Keychain で別の Mac から届いた変更を OS の候補へ反映するために App 側で購読する
final class TatamiAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidBecomeActive(_ notification: Notification) {
        let store = KeychainCredentialStore()
        Task {
            await CredentialIdentityRegistrar.sync(store: store)
        }
    }
}

/// Tatami のエントリポイント。ウィンドウ管理 (#4) の実装までは、ウィンドウ 1 つに BrowserWindowView を置く
@main
struct TatamiApp: App {
    @NSApplicationDelegateAdaptor(TatamiAppDelegate.self) private var appDelegate

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
