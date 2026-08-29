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
    static func serviceIdentifier(credential: Credential) -> ASCredentialServiceIdentifier? {
        guard var components = URLComponents(url: credential.url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), let host = components.encodedHost, !host.isEmpty else {
            return nil
        }
        components.scheme = scheme
        components.encodedHost = host.lowercased()
        components.user = nil
        components.password = nil
        components.path = "/"
        components.query = nil
        components.fragment = nil
        // 既定ポートの明示 (https の 443・http の 80) はページ側の省略形の識別子と一致するよう外す (CredentialMatcher と同じ扱い)
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        if components.port == defaultPort {
            components.port = nil
        }
        guard let identifier = components.string else {
            return nil
        }
        return ASCredentialServiceIdentifier(identifier: identifier, type: .URL)
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
            let identities = credentials.compactMap { credential -> ASPasswordCredentialIdentity? in
                guard let serviceIdentifier = serviceIdentifier(credential: credential) else {
                    return nil
                }
                return ASPasswordCredentialIdentity(serviceIdentifier: serviceIdentifier, user: credential.username, recordIdentifier: credential.id.uuidString)
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
