import LicenseList
import SwiftUI

/// Tatami のエントリポイント。ウィンドウ管理 (#4) の実装までは、ウィンドウ 1 つに BrowserWindowView を置く
@main
struct TatamiApp: App {
    /// 同じライセンスウィンドウを再利用し、メニューの再選択で増殖させないための標準アクション。
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Tatami") {
            BrowserWindowView()
                // 他アプリからの URL は既存のウィンドウで受ける (新しい macOS ウィンドウを作らない)。documents/PROJECT.md 機能要件 4
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            PaneCommands()
            CommandGroup(after: .appInfo) {
                Button("OSS ライセンス") {
                    openWindow(id: "oss-licenses")
                }
                .accessibilityIdentifier("menu-oss-licenses")
            }
        }

        Window("OSS ライセンス", id: "oss-licenses") {
            NavigationStack {
                LicenseListView()
                    .licenseViewStyle(.withRepositoryAnchorLink)
                    .navigationTitle("OSS ライセンス")
                    .accessibilityIdentifier("oss-license-list")
            }
            // 一覧とライセンス本文を読める最小サイズを確保する。
            .frame(minWidth: 480, minHeight: 360)
        }
        // 本文の行幅とスクロール領域を確保する初期サイズ。
        .defaultSize(width: 640, height: 480)
        .defaultLaunchBehavior(.suppressed)
    }
}
