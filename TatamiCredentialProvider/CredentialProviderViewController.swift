import AppKit
import AuthenticationServices
import SwiftUI

/// OS の自動入力 (Safari を含む全アプリ) から呼ばれる Credential Provider Extension の入口。
/// 資格情報はアプリと同じ Keychain ストア (KeychainCredentialStore。Release では共有 access group) から読み、
/// 読む前に Touch ID / パスワードで本人確認する (CredentialLock。自動ロックの時間は拡張の既定値)
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let store = KeychainCredentialStore()
    private let model = CredentialProviderModel()
    /// 要求の世代。同じ view controller で次の要求が始まった時に、前の要求の非同期処理が古い候補を出さないようにする
    private var requestGeneration = 0

    /// 新しい要求の開始。前の要求の候補・メッセージを消し、以後の非同期処理はこの世代のものだけが表示を更新する
    private func beginRequest(mode: CredentialProviderModel.Mode) -> Int {
        requestGeneration += 1
        model.mode = mode
        model.credentials = []
        model.message = nil
        return requestGeneration
    }

    override func loadView() {
        let hosting = NSHostingView(rootView: CredentialProviderView(model: model, onSelect: { [weak self] credential in
            self?.select(credential: credential)
        }, onCancel: { [weak self] in
            self?.cancel(code: .userCanceled)
        }, onFinishConfiguration: { [weak self] in
            self?.finishConfiguration()
        }))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        view = hosting
    }

    /// 候補の一覧を求められた時。サービス識別子 (ドメインか URL) に合う資格情報だけを出す
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        let generation = beginRequest(mode: .list)
        Task {
            do {
                try await CredentialLock.shared.ensureUnlocked(reason: "自動入力する資格情報を読む")
                guard generation == requestGeneration else {
                    return
                }
                let all = try store.all()
                let pageURLs = serviceIdentifiers.compactMap(CredentialProviderModel.pageURL(serviceIdentifier:))
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
        cancel(code: .userInteractionRequired)
    }

    /// 候補 (ASCredentialIdentityStore に登録した識別子) が選ばれた時。本人確認してからその 1 件を返す
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        let generation = beginRequest(mode: .list)
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
        Task {
            do {
                try await CredentialLock.shared.ensureUnlocked(reason: "自動入力の候補を登録する")
                await CredentialIdentityRegistrar.sync(store: store)
            } catch {
                model.message = "\(error)"
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
                try await CredentialLock.shared.ensureUnlocked(reason: "\(credential.username) を自動入力する")
                guard generation == requestGeneration else {
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
    var credentials: [Credential] = []
    /// 候補が無い・本人確認に失敗した等の表示
    var message: String?

    /// サービス識別子をページの URL に読み替える。ドメイン型は https のトップとして扱う (CredentialMatcher が http の資格情報も候補に含める)
    static func pageURL(serviceIdentifier: ASCredentialServiceIdentifier) -> URL? {
        switch serviceIdentifier.type {
        case .domain:
            return URL(string: "https://\(serviceIdentifier.identifier)/")
        case .URL:
            return URL(string: serviceIdentifier.identifier)
        default:
            // 将来の種類 (SDK に追加されたもの) は URL に読み替えられないため候補を出さない
            return nil
        }
    }
}

/// 拡張の画面。候補を選ぶと充填し、Escape / キャンセルで閉じる
struct CredentialProviderView: View {
    let model: CredentialProviderModel
    let onSelect: (Credential) -> Void
    let onCancel: () -> Void
    let onFinishConfiguration: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.mode {
            case .configuration:
                Text("Tatami の Password Manager に保存した資格情報を Safari や他のアプリに自動入力します")
                Text("資格情報の保存・インポートは Tatami のウィンドウで行います (prefix + a / :import-passwords)")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("完了", action: onFinishConfiguration)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("finishConfigurationButton")
                }
            case .list:
                Text("Tatami の資格情報")
                    .font(.headline)
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
                            Text(credential.host)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("credentialRow-\(credential.id.uuidString)")
                }
                HStack {
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
