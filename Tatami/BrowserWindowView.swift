import SwiftUI

/// 1 ウィンドウ分のブラウザ画面。アドレスバーと、ペインツリーどおりに WKWebView を並べる PaneContainer を持つ
struct BrowserWindowView: View {
    @State private var model: BrowserWindowModel?
    /// モデルの遅延生成中に受け取った外部 URL。生成後に受信順のまま開く
    @State private var pendingOpenedURLs: [URL] = []

    var body: some View {
        Group {
            if let model {
                BrowserWindowContent(model: model)
            } else {
                Color.clear
                    .frame(minWidth: 800, minHeight: 600)
                    .accessibilityIdentifier("windowLoading")
            }
        }
        .task {
            guard model == nil else {
                return
            }
            // WindowGroup はメニューのキー処理中の display cycle で View を構築することがある。次の run loop まで待ち、
            // 保存済みセッションの復元に伴う WKWebView の同期 IPC をメニュー処理の外で始める
            try? await Task.sleep(for: .milliseconds(1))
            guard !Task.isCancelled, model == nil else {
                return
            }
            let model = BrowserWindowModel()
            model.activate()
            self.model = model
            for openedURL in pendingOpenedURLs {
                model.open(url: openedURL)
            }
            pendingOpenedURLs.removeAll()
        }
        .onDisappear {
            model?.deactivate()
        }
        // モデルの準備前に URL 経由でコールド起動してもイベントを失わないよう、この外側の View で受ける
        .onOpenURL { openedURL in
            if let model {
                model.open(url: openedURL)
            } else {
                pendingOpenedURLs.append(openedURL)
            }
        }
    }
}

/// BrowserWindowModel の準備後に表示する画面。モデルの生成は BrowserWindowView がメニュー処理の外へ遅延する
private struct BrowserWindowContent: View {
    @Bindable var model: BrowserWindowModel
    /// プロンプトを開いた時にキーボードフォーカスを入力欄へ移す (アドレスバーに残ったままだと入力がそちらへ行く)
    @FocusState private var isPromptFocused: Bool
    /// prefix + / でアドレスバーへフォーカスを移すためのフォーカス状態
    @FocusState private var isAddressFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    model.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)
                .accessibilityIdentifier("backButton")
                Button {
                    model.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canGoForward)
                .accessibilityIdentifier("forwardButton")
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("reloadButton")
                TextField("URL または検索語", text: $model.addressText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isAddressFieldFocused)
                    .accessibilityIdentifier("addressField")
                    .onSubmit {
                        model.submitAddressBar()
                        isAddressFieldFocused = false
                    }
                    .onChange(of: model.addressText) {
                        model.addressTextDidChange()
                    }
                    .onKeyPress(.downArrow) {
                        model.moveAddressSuggestion(delta: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        model.moveAddressSuggestion(delta: -1)
                        return .handled
                    }
            }
            .padding(8)
            // 読み込み中だけ進捗バーを出す。高さを固定して表示の切り替えでレイアウトが動かないようにする
            ProgressView(value: model.focusedPaneProgress ?? 0)
                .progressViewStyle(.linear)
                .opacity(model.focusedPaneProgress == nil ? 0 : 1)
                .frame(height: 4)
                .accessibilityIdentifier("loadProgress")
            PaneContainer(model: model)
                .overlay(alignment: .topLeading) {
                    if model.chooser != nil {
                        chooserList
                    } else if isAddressFieldFocused, !model.addressSuggestions.isEmpty {
                        addressSuggestionList
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
        .onChange(of: model.addressBarFocusRequestCount) {
            isAddressFieldFocused = true
        }
        // アドレスバーの編集中は find モードの n / N / Escape (と提案の y / n) を消費しないよう、フォーカス状態をモデルへ反映する
        .onChange(of: isAddressFieldFocused, initial: true) { _, focused in
            model.isAddressBarEditing = focused
        }
        // detach はセッションを保存した上でこの macOS ウィンドウを閉じる。再起動や File > New Window で復元される
        .onChange(of: model.detachRequestCount) {
            NSApplication.shared.keyWindow?.close()
        }
        .navigationTitle(model.focusedPageTitle)
    }

    /// status line 左側のウィンドウ一覧。ウィンドウが多い・名前が長い時も現在のウィンドウが見えるよう、横スクロールで現在の項目へ追従する
    private var windowList: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("[\(model.sessionName)]")
                        .accessibilityIdentifier("sessionName")
                    ForEach(Array(model.windows.enumerated()), id: \.offset) { index, window in
                        Text("\(index):\(window.name)\(index == model.currentWindowIndex ? "*" : "")")
                            .id(index)
                    }
                }
            }
            .onChange(of: model.currentWindowIndex, initial: true) { _, index in
                proxy.scrollTo(index)
            }
            // 名前の変化 (rename・automatic-rename) で項目の幅が変わっても現在の項目が見えるよう追従する
            .onChange(of: model.statusLineText) {
                proxy.scrollTo(model.currentWindowIndex)
            }
        }
        .accessibilityIdentifier("windowList")
        .accessibilityLabel(model.statusLineText)
    }

    /// tmux の status line に相当する最下段。左にセッション名とウィンドウ一覧、右に prefix 待ち。プロンプト中は入力欄に置き換わる
    private var statusLine: some View {
        HStack {
            if let prompt = model.prompt {
                Text(promptLabel(prompt: prompt))
                    .accessibilityIdentifier("promptLabel")
                TextField("", text: $model.promptText)
                    .textFieldStyle(.plain)
                    .focused($isPromptFocused)
                    .onKeyPress(.upArrow) {
                        model.recallOlderCommand()
                        return model.prompt == .command ? .handled : .ignored
                    }
                    .onKeyPress(.downArrow) {
                        model.recallNewerCommand()
                        return model.prompt == .command ? .handled : .ignored
                    }
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
            } else if let proposal = model.proposal {
                Text(proposal.text)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("proposal")
            } else if let statusMessage = BrowsingDataStore.shared.lastSaveError ?? model.statusMessage {
                // 履歴の保存は非同期 (debounce) のため、失敗はストアのエラー状態を表示側で監視し、成功メッセージより優先して出す
                Text(statusMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("statusMessage")
            } else {
                windowList
            }
            Spacer()
            // 資格情報のロック状態。ロック中の充填・エクスポートは本人確認を求めることが分かるよう常に出す
            Text(model.isCredentialLocked ? "🔒" : "🔓")
                .accessibilityIdentifier("credentialLockIndicator")
                .accessibilityLabel(model.isCredentialLocked ? "locked" : "unlocked")
            Text(model.prefixKeyState == .awaitingCommand ? model.keyBindings.prefix.tmuxKeyName : "")
                .accessibilityIdentifier("prefixIndicator")
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(.bar)
        .accessibilityIdentifier("statusLine")
    }

    /// プロンプトの種類の表示。コマンドプロンプトは tmux と同じく `:` を出す
    private func promptLabel(prompt: BrowserWindowModel.Prompt) -> String {
        switch prompt {
        case .renameWindow:
            return "(rename-window)"
        case .renameSession:
            return "(rename-session)"
        case .command:
            return ":"
        case .find:
            return "/"
        }
    }

    /// アドレスバーの候補 (ブックマーク → 履歴)。上下キーで選び Enter で開く
    private var addressSuggestionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.addressSuggestions.enumerated()), id: \.offset) { index, suggestion in
                HStack(spacing: 6) {
                    Image(systemName: suggestion.isBookmark ? "bookmark.fill" : "clock")
                        .foregroundStyle(.secondary)
                    Text(suggestion.title)
                        .lineLimit(1)
                    Text(suggestion.url.absoluteString)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(index == model.addressSuggestionIndex ? Color.accentColor.opacity(0.3) : Color.clear)
                .accessibilityIdentifier("suggestionRow-\(index)")
            }
        }
        .font(.system(.body, design: .monospaced))
        .padding(8)
        .frame(width: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .accessibilityIdentifier("addressSuggestions")
    }

    /// choose-window / choose-session の一覧。j / k / 数字 / Enter / Escape はモデルのキー処理で受ける
    private var chooserList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.chooserItems.enumerated()), id: \.offset) { index, name in
                        Text("(\(index)) \(name)")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == model.chooserSelectionIndex ? Color.accentColor.opacity(0.3) : Color.clear)
                            .accessibilityIdentifier("chooserRow-\(index)")
                            .id(index)
                    }
                }
            }
            .onChange(of: model.chooserSelectionIndex, initial: true) { _, index in
                proxy.scrollTo(index)
            }
        }
        .font(.system(.body, design: .monospaced))
        .padding(8)
        // 一覧が長い時に画面の半分程度で止めてスクロールさせる
        .frame(width: 320)
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .accessibilityIdentifier("chooser")
    }
}
