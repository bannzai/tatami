import AppKit
import AuthenticationServices
import SwiftUI

/// OS の自動入力 (Safari を含む全アプリ) から呼ばれる Credential Provider Extension の入口。
/// 資格情報はアプリと同じ Keychain ストア (KeychainCredentialStore。Release では共有 access group) から読み、
/// 読む前に Touch ID / パスワードで本人確認する (CredentialLock。自動ロックの時間は拡張の既定値)
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let store = KeychainCredentialStore()
    private let model = CredentialProviderModel()
    /// 現在の要求のサービス識別子。候補の選択時に、その時点のストアの内容と要求先を照合し直すために持つ
    private var currentServiceIdentifiers: [ASCredentialServiceIdentifier] = []
    /// 一覧を出すために本人確認した時刻。同じ要求の中で候補を選ぶ時は、一覧を長く開いたままでなければ再確認しない
    /// (拡張は要求ごとに確認する設定のため、そのままだと 1 回の自動入力で 2 回確認になる)
    private var listAuthenticatedAt: ContinuousClock.Instant?
    /// 一覧の失効タスク (一定時間で候補表示を消す)
    private var listExpiryTask: Task<Void, Never>?
    /// 要求の世代。同じ view controller で次の要求が始まった時に、前の要求の非同期処理が古い候補を出さないようにする
    private var requestGeneration = 0

    /// 新しい要求の開始。前の要求の候補・メッセージを消し、以後の非同期処理はこの世代のものだけが表示を更新する
    private func beginRequest(mode: CredentialProviderModel.Mode) -> Int {
        requestGeneration += 1
        model.mode = mode
        model.credentials = []
        model.message = nil
        model.expired = false
        listAuthenticatedAt = nil
        listExpiryTask?.cancel()
        listExpiryTask = nil
        return requestGeneration
    }

    /// 一覧を表示してから自動ロック時間が過ぎたら、表示中のユーザー名・ホストを消して再度本人確認を求める (他人が覗けないように)
    private func scheduleListExpiry(generation: Int) {
        listExpiryTask?.cancel()
        listExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CredentialLockPolicy.defaultLockTimeout))
            guard let self, !Task.isCancelled, generation == self.requestGeneration else {
                return
            }
            self.model.credentials = []
            self.model.message = "時間が経過したため再度本人確認が必要です"
            self.model.expired = true
            self.listAuthenticatedAt = nil
        }
    }

    /// 失効した一覧で「再認証」を押した時。同じ要求のサービス識別子で本人確認と候補の取得をやり直す
    private func reauthenticateList() {
        prepareCredentialList(for: currentServiceIdentifiers)
    }

    override func loadView() {
        // 拡張は tatami.conf (App Sandbox の外) を読めず lock-timeout を共有できないため、要求ごとに本人確認する (timeout 0 と同じ)
        CredentialLock.shared.apply(lockTimeout: 0)
        let hosting = NSHostingView(rootView: CredentialProviderView(model: model, onSelect: { [weak self] credential in
            self?.select(credential: credential)
        }, onCancel: { [weak self] in
            self?.cancel(code: .userCanceled)
        }, onReauthenticate: { [weak self] in
            self?.reauthenticateList()
        }, onFinishConfiguration: { [weak self] in
            self?.finishConfiguration()
        }))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        view = hosting
    }

    /// 候補の一覧を求められた時。サービス識別子 (ドメインか URL) に合う資格情報だけを出す
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        let generation = beginRequest(mode: .list)
        currentServiceIdentifiers = serviceIdentifiers
        Task {
            do {
                try await CredentialLock.shared.ensureUnlocked(reason: "自動入力する資格情報を読む")
                guard generation == requestGeneration else {
                    return
                }
                listAuthenticatedAt = .now
                scheduleListExpiry(generation: generation)
                let all = try store.all()
                let pageURLs = CredentialProviderModel.pageURLs(serviceIdentifiers: serviceIdentifiers)
                var seen = Set<UUID>()
                model.credentials = pageURLs
                    .flatMap { CredentialMatcher.candidates(credentials: all, pageURL: $0) }
                    .filter { seen.insert($0.id).inserted }
                model.message = model.credentials.isEmpty ? "このサイトの資格情報は無い" : nil
            } catch {
                if generation == requestGeneration {
                    model.message = "\(error)"
                }
            }
        }
    }

    /// UI なしで充填を求められた時。本人確認 (UI) が要るため、UI ありで呼び直してもらう
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        // 前の要求で本人確認を待っている処理がこの要求の context に完了しないよう、世代を進めてから断る
        _ = beginRequest(mode: .list)
        cancel(code: .userInteractionRequired)
    }

    /// 候補 (ASCredentialIdentityStore に登録した識別子) が選ばれた時。本人確認してからその 1 件を返す
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        let generation = beginRequest(mode: .list)
        currentServiceIdentifiers = [credentialRequest.credentialIdentity.serviceIdentifier]
        guard let recordIdentifier = credentialRequest.credentialIdentity.recordIdentifier, let id = UUID(uuidString: recordIdentifier) else {
            cancel(code: .credentialIdentityNotFound)
            return
        }
        Task {
            do {
                try await CredentialLock.shared.ensureUnlocked(reason: "自動入力する資格情報を読む")
                guard generation == requestGeneration else {
                    return
                }
                // OS が識別子で選んだ 1 件でも、要求元のサイトと資格情報の照合 (https → http の降格禁止・ポート) はアプリ内の充填と同じ規則で行う
                guard let credential = try store.all().first(where: { $0.id == id }),
                      let pageURL = CredentialProviderModel.pageURL(serviceIdentifier: credentialRequest.credentialIdentity.serviceIdentifier),
                      CredentialMatcher.matches(credentialURL: credential.url, pageURL: pageURL) else {
                    cancel(code: .credentialIdentityNotFound)
                    return
                }
                complete(credential: credential)
            } catch {
                if generation == requestGeneration {
                    model.message = "\(error)"
                }
            }
        }
    }

    /// システム設定で Tatami を自動入力に選んだ時に出る説明
    override func prepareInterfaceForExtensionConfiguration() {
        _ = beginRequest(mode: .configuration)
    }

    /// 設定画面の完了。有効化した直後から候補が出るよう、この時点でストアの全件を OS の候補に登録してから閉じる
    /// (アプリ側の同期はプロバイダが有効な時にしか登録できないため)
    private func finishConfiguration() {
        let generation = requestGeneration
        Task {
            do {
                try await CredentialLock.shared.ensureUnlocked(reason: "自動入力の候補を登録する")
            } catch {
                if generation == requestGeneration {
                    model.message = "\(error)"
                }
                return
            }
            let synced = await CredentialIdentityRegistrar.sync(store: store)
            guard generation == requestGeneration else {
                return
            }
            // 登録に失敗した時は閉じずに知らせ、もう一度「完了」で再試行できるようにする
            guard synced else {
                model.message = "自動入力候補の登録に失敗した (もう一度「完了」で再試行)"
                return
            }
            extensionContext.completeExtensionConfigurationRequest()
        }
    }

    /// 候補の選択。一覧を開いたまま自動ロックの期限を過ぎていることがあるため、返す直前にも本人確認する (アンロック中なら即時)
    private func select(credential: Credential) {
        let generation = requestGeneration
        Task {
            do {
                // 再認証の省略可否は充填の直前に判定する (クリックからここまでの間に一覧が時間失効して listAuthenticatedAt が消えることがあるため)
                let recentlyAuthenticated = listAuthenticatedAt.map { ContinuousClock.now - $0 < .seconds(CredentialLockPolicy.defaultLockTimeout) } ?? false
                if !recentlyAuthenticated {
                    try await CredentialLock.shared.ensureUnlocked(reason: "\(credential.username) を自動入力する")
                }
                guard generation == requestGeneration else {
                    return
                }
                // 一覧を作ってから (別プロセスや iCloud 同期で) 更新・削除されていることがあるため、ストアから読み直して要求先と照合し直す
                let pageURLs = CredentialProviderModel.pageURLs(serviceIdentifiers: currentServiceIdentifiers)
                guard let current = try store.all().first(where: { $0.id == credential.id }),
                      pageURLs.contains(where: { CredentialMatcher.matches(credentialURL: current.url, pageURL: $0) }) else {
                    model.message = "資格情報が変更または削除されたため充填しない"
                    model.credentials.removeAll { $0.id == credential.id }
                    return
                }
                complete(credential: current)
            } catch {
                if generation == requestGeneration {
                    model.message = "\(error)"
                }
            }
        }
    }

    private func complete(credential: Credential) {
        extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: credential.username, password: credential.password))
    }

    private func cancel(code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }
}

/// 拡張の画面の状態。一覧と、システム設定から開かれた時の説明の 2 つ
@Observable
final class CredentialProviderModel {
    /// 表示の種類
    enum Mode {
        case list
        case configuration
    }

    var mode = Mode.list
    /// 一覧が時間で失効し再認証が要る状態か (要求内で復帰する導線を出すため)
    var expired = false
    var credentials: [Credential] = []
    /// 候補が無い・本人確認に失敗した等の表示
    var message: String?

    /// サービス識別子をページの URL に読み替える。ドメイン型は https のトップとして扱う (CredentialMatcher が http の資格情報も候補に含める)
    nonisolated static func pageURL(serviceIdentifier: ASCredentialServiceIdentifier) -> URL? {
        switch serviceIdentifier.type {
        case .domain:
            // ドメイン型は scheme を持たないため https として扱う。Unicode の U-label (例え.jp) も Foundation が A-label へ変換する host に設定し、
            // IPv6 のホストは角括弧で囲む
            var components = URLComponents()
            components.scheme = "https"
            let raw = serviceIdentifier.identifier
            components.host = raw.contains(":") && !raw.hasPrefix("[") ? "[\(raw)]" : raw
            components.path = "/"
            return components.url
        case .URL:
            return URL(string: serviceIdentifier.identifier)
        default:
            // 将来の種類 (SDK に追加されたもの) は URL に読み替えられないため候補を出さない
            return nil
        }
    }

    /// 要求元のページ URL。scheme を持つ URL 型の識別子があればそれだけを使う
    /// (同時に渡されたドメイン型を https と決めつけて、http のページに https 用の資格情報を出さないため)
    nonisolated static func pageURLs(serviceIdentifiers: [ASCredentialServiceIdentifier]) -> [URL] {
        let urlTyped = serviceIdentifiers.filter { $0.type == .URL }
        return (urlTyped.isEmpty ? serviceIdentifiers : urlTyped).compactMap(pageURL(serviceIdentifier:))
    }
}

/// 拡張の画面。候補を選ぶと充填し、Escape / キャンセルで閉じる
struct CredentialProviderView: View {
    let model: CredentialProviderModel
    let onSelect: (Credential) -> Void
    let onCancel: () -> Void
    let onReauthenticate: () -> Void
    let onFinishConfiguration: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.mode {
            case .configuration:
                Text("Tatami の Password Manager に保存した資格情報を Safari や他のアプリに自動入力します")
                    .accessibilityIdentifier("configurationSummary")
                Text("資格情報の保存・インポートは Tatami のウィンドウで行います (prefix + a / :import-passwords)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("configurationDetail")
                HStack {
                    Spacer()
                    Button("完了", action: onFinishConfiguration)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("finishConfigurationButton")
                }
            case .list:
                Text("Tatami の資格情報")
                    .font(.headline)
                    .accessibilityIdentifier("credentialListHeader")
                if let message = model.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("providerMessage")
                }
                List(model.credentials) { credential in
                    Button {
                        onSelect(credential)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(credential.username)
                                .accessibilityIdentifier("credentialUsername-\(credential.id.uuidString)")
                            Text(credential.host)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                .accessibilityIdentifier("credentialHost-\(credential.id.uuidString)")
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("credentialRow-\(credential.id.uuidString)")
                }
                .accessibilityIdentifier("credentialList")
                HStack {
                    if model.expired {
                        Button("再認証", action: onReauthenticate)
                            .accessibilityIdentifier("reauthenticateButton")
                    }
                    Spacer()
                    Button("キャンセル", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("cancelButton")
                }
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 360)
    }
}
