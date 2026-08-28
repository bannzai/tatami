import SwiftUI

/// 1 ウィンドウ分のブラウザ画面。ペインツリー実装前の暫定として、アドレスバーと 1 枚の WebPaneView だけを持つ
struct BrowserWindowView: View {
    /// アドレスバーに入力中のテキスト
    @State private var addressText = ""
    /// 現在ペインに表示している URL
    @State private var currentURL = AddressInput.homeURL

    var body: some View {
        VStack(spacing: 0) {
            TextField("URL または検索語", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("addressField")
                .onSubmit {
                    currentURL = AddressInput.resolve(text: addressText)
                }
                .padding(8)
            WebPaneView(url: currentURL)
                .accessibilityIdentifier("webPane")
        }
        // 2 分割しても各ペインが実用的な幅になる最小サイズとして、一般的なノート PC の画面の半分程度を選んだ
        .frame(minWidth: 800, minHeight: 600)
    }
}
