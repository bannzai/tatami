import SwiftUI

/// 1 ウィンドウ分のブラウザ画面。アドレスバーと、ペインツリーどおりに WKWebView を並べる PaneContainer を持つ
struct BrowserWindowView: View {
    @State private var model = BrowserWindowModel()

    var body: some View {
        VStack(spacing: 0) {
            TextField("URL または検索語", text: $model.addressText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("addressField")
                .onSubmit {
                    model.navigate(text: model.addressText)
                }
                .padding(8)
            PaneContainer(model: model)
        }
        // 2 分割しても各ペインが実用的な幅になる最小サイズとして、一般的なノート PC の画面の半分程度を選んだ
        .frame(minWidth: 800, minHeight: 600)
        .focusedSceneValue(\.browserWindowModel, model)
        // Info.plist の CFBundleURLTypes (http / https) で他アプリから渡された URL をフォーカス中のペインで開く
        .onOpenURL { openedURL in
            model.open(url: openedURL)
        }
    }
}
