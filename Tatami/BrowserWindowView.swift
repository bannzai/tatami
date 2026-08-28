import SwiftUI

/// 1 ウィンドウ分のブラウザ画面。アドレスバーと、ペインツリーどおりに WKWebView を並べる PaneContainer を持つ
struct BrowserWindowView: View {
    @State private var model = BrowserWindowModel()
    /// プロンプトを開いた時にキーボードフォーカスを入力欄へ移す (アドレスバーに残ったままだと入力がそちらへ行く)
    @FocusState private var isPromptFocused: Bool

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
                .overlay(alignment: .topLeading) {
                    if model.isChoosingWindow {
                        windowChooser
                    }
                }
            statusLine
        }
        // 2 分割しても各ペインが実用的な幅になる最小サイズとして、一般的なノート PC の画面の半分程度を選んだ
        .frame(minWidth: 800, minHeight: 600)
        .focusedSceneValue(\.browserWindowModel, model)
        .onChange(of: model.prompt) { _, prompt in
            isPromptFocused = prompt != nil
        }
        // Info.plist の CFBundleURLTypes (http / https) で他アプリから渡された URL をフォーカス中のペインで開く
        .onOpenURL { openedURL in
            model.open(url: openedURL)
        }
    }

    /// tmux の status line に相当する最下段。左にセッション名とウィンドウ一覧、右に prefix 待ち。プロンプト中は入力欄に置き換わる
    private var statusLine: some View {
        HStack {
            if model.prompt == .renameWindow {
                Text("(rename-window)")
                TextField("", text: $model.promptText)
                    .textFieldStyle(.plain)
                    .focused($isPromptFocused)
                    // onChange(of: prompt) と同じ更新で入力欄が現れる時に FocusState の反映が抜けることがあるため、出現時にも求める
                    .onAppear {
                        isPromptFocused = true
                    }
                    .accessibilityIdentifier("promptField")
                    .onSubmit {
                        model.commitPrompt()
                    }
                    .onExitCommand {
                        model.cancelPrompt()
                    }
            } else {
                Text(model.statusLineText)
                    .accessibilityIdentifier("windowList")
            }
            Spacer()
            Text(model.prefixKeyState == .awaitingCommand ? model.keyBindings.prefix.tmuxKeyName : "")
                .accessibilityIdentifier("prefixIndicator")
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(.bar)
        .accessibilityIdentifier("statusLine")
    }

    /// choose-window の一覧。j / k / 数字 / Enter / Escape はモデルのキー処理で受ける
    private var windowChooser: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.windows.enumerated()), id: \.offset) { index, window in
                Text("(\(index)) \(window.name)")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == model.chooserSelectionIndex ? Color.accentColor.opacity(0.3) : Color.clear)
            }
        }
        .font(.system(.body, design: .monospaced))
        .padding(8)
        .frame(width: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .accessibilityIdentifier("windowChooser")
    }
}
