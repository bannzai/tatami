import SwiftUI
import WebKit

/// WKWebView を SwiftUI に載せる 1 ペイン分の Web コンテンツ。
/// SwiftUI 側から渡された url が変わった時だけ読み込み、ページ内のリンク遷移で変わった webView.url は上書きしない
struct WebPaneView: NSViewRepresentable {
    /// SwiftUI 側が表示を要求する URL
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Chromium の DevTools 相当として Safari の Web Inspector を使えるようにする (ADR 0001)
        webView.isInspectable = true
        load(url: url, into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.requestedURL != url {
            load(url: url, into: webView, coordinator: context.coordinator)
        }
    }

    private func load(url: URL, into webView: WKWebView, coordinator: Coordinator) {
        coordinator.requestedURL = url
        webView.load(URLRequest(url: url))
    }

    /// SwiftUI 側が最後に要求した URL を覚え、再描画のたびに同じ URL を再読み込みしないようにする
    final class Coordinator {
        /// 最後に load した URL
        var requestedURL: URL?
    }
}
