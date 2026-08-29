import AuthenticationServices
import Foundation

/// OS の自動入力候補 (ASCredentialIdentityStore) に Password Manager の資格情報の識別子を登録する。
/// 識別子はサイトのオリジン (scheme・host・port を保つ URL 型)・ユーザー名・レコード ID (Credential.id) だけで、パスワードは登録しない
/// (充填時に拡張が Keychain から読む)
enum CredentialIdentityRegistrar {
    /// 直列化のための世代。sync は非同期 (state の取得と置換で中断する) なので、古いスナップショットが後から置換して
    /// 新しい保存を消さないよう、置換は 1 つずつ順に行い、実行時点で最新の呼び出しだけが置換する
    private static var generation = 0
    /// 直前の同期。次の同期はこれの完了を待ってから置換する (置換の完了順を呼び出し順に揃える)
    private static var previous: Task<Bool, Never>?

    /// 資格情報を OS に登録する識別子。オリジンをそのまま URL 型で持たせ、http と https・別ポートを OS 側でも区別させる。
    /// ホストは IDNA の ASCII 形 (`encodedHost`) と IPv6 の角括弧を保つため、文字列の連結ではなく URLComponents で組み立てる
    static func serviceIdentifier(credential: Credential, scheme overrideScheme: String? = nil) -> ASCredentialServiceIdentifier? {
        guard var components = URLComponents(url: credential.url, resolvingAgainstBaseURL: false),
              let originalScheme = components.scheme?.lowercased(),
              // ホストは照合時と同じ正規化 (IPv6 の標準形・末尾ドット除去・IDNA の A-label) を使う
              let host = CredentialMatcher.host(url: credential.url), !host.isEmpty else {
            return nil
        }
        // 元の scheme の既定ポート (http の 80・https の 443) の明示は省略形と同一オリジンなので、scheme を昇格する前に外す
        // (http://example.com:80 → https identity を https://example.com/ にする。CredentialMatcher と同じ扱い)
        let originalDefaultPort = originalScheme == "https" ? 443 : (originalScheme == "http" ? 80 : nil)
        let scheme = overrideScheme ?? originalScheme
        components.scheme = scheme
        // host は CredentialMatcher.host が IPv6 を角括弧付きの標準形で返すためそのまま使う (二重に囲まない)
        components.encodedHost = host
        components.user = nil
        components.password = nil
        components.path = "/"
        components.query = nil
        components.fragment = nil
        let targetDefaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        if components.port == originalDefaultPort || components.port == targetDefaultPort {
            components.port = nil
        }
        guard let identifier = components.string else {
            return nil
        }
        return ASCredentialServiceIdentifier(identifier: identifier, type: .URL)
    }

    /// 1 つの資格情報が対応するサービス識別子。http で保存した項目は、CredentialMatcher が http→https の昇格を許すため https 用も登録する
    static func serviceIdentifiers(credential: Credential) -> [ASCredentialServiceIdentifier] {
        var identifiers = [serviceIdentifier(credential: credential)].compactMap { $0 }
        if credential.url.scheme?.lowercased() == "http", let https = serviceIdentifier(credential: credential, scheme: "https") {
            identifiers.append(https)
        }
        return identifiers
    }

    /// ストアの全件で OS 側の一覧を置き換える。同じ内容で何度呼んでも同じ状態になる (追加ではなく置換)。
    /// システム設定で Tatami が自動入力プロバイダに選ばれていない間は何もしない (状態が無効の時の登録は捨てられる)
    @discardableResult
    static func sync(credentials: [Credential]) async -> Bool {
        await sync(generation: nextGeneration()) { credentials }
    }

    /// ストアを読んで sync する。プロバイダが無効なら Keychain を読まずに終える (ウィンドウごとのアクティブ化通知で全件走査を繰り返さない)。
    /// 読めなかった時は OS 側の候補を消さずに (空で置換せずに) 中止する
    @discardableResult
    static func sync(store: any CredentialStore) async -> Bool {
        await sync(generation: nextGeneration()) {
            do {
                return try store.all()
            } catch {
                NSLog("自動入力候補の同期を中止 (資格情報を読めない): %@", "\(error)")
                return nil
            }
        }
    }

    private static func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    /// 同期の本体。直前の同期の完了を待ち、有効状態の確認 → 読み取り → 置換の各段階で最新の呼び出しでなければ中止する
    /// 同期の本体。直前の同期の完了を待ち、有効状態の確認 → 読み取り → 置換の各段階で最新の呼び出しでなければ中止する。
    /// 置換まで完了したら true (無効・中止・失敗は false)
    private static func sync(generation mine: Int, load: @escaping @MainActor () -> [Credential]?) async -> Bool {
        let waitFor = previous
        let task = Task<Bool, Never> {
            _ = await waitFor?.value
            guard mine == generation, await ASCredentialIdentityStore.shared.state().isEnabled, mine == generation,
                  let credentials = load() else {
                return false
            }
            let identities = credentials.flatMap { credential in
                serviceIdentifiers(credential: credential).map {
                    ASPasswordCredentialIdentity(serviceIdentifier: $0, user: credential.username, recordIdentifier: credential.id.uuidString)
                }
            }
            do {
                try await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
                return true
            } catch {
                // 候補の登録は補助機能で、失敗しても Tatami 内の充填には影響しない。次の保存で再登録される
                NSLog("自動入力候補の登録に失敗: %@", "\(error)")
                return false
            }
        }
        previous = task
        return await task.value
    }
}
