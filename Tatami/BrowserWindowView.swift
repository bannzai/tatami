import SwiftUI

/// 1 ウィンドウ分のブラウザ画面。ペインツリー実装前の暫定として、アドレスバーと 1 枚の WebPaneView だけを持つ
struct BrowserWindowView: View {
    /// アドレスバーに入力中のテキスト
    @State private var addressText = ""
    /// SwiftUI 側からペインに表示を要求する URL
    @State private var requestedURL = AddressInput.homeURL

    var body: some View {
        VStack(spacing: 0) {
            TextField("URL または検索語", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("addressField")
                .onSubmit {
                    requestedURL = AddressInput.resolve(text: addressText)
                }
                .padding(8)
            WebPaneView(url: requestedURL) { navigatedURL in
                // ページ内リンクやリダイレクトで移動した先をアドレスバーに反映する
                addressText = navigatedURL.absoluteString
            }
            .accessibilityIdentifier("webPane")
        }
        // 2 分割しても各ペインが実用的な幅になる最小サイズとして、一般的なノート PC の画面の半分程度を選んだ
        .frame(minWidth: 800, minHeight: 600)
        // Info.plist の CFBundleURLTypes (http / https) で他アプリから渡された URL を現在のペインで開く
        .onOpenURL { openedURL in
            addressText = openedURL.absoluteString
            requestedURL = openedURL
        }
    }
}
