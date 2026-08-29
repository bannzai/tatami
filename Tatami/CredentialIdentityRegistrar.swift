import AuthenticationServices
import Foundation

/// OS の自動入力候補 (ASCredentialIdentityStore) に Password Manager の資格情報の識別子を登録する。
/// 識別子はサイトのオリジン (scheme・host・port を保つ URL 型)・ユーザー名・レコード ID (Credential.id) だけで、パスワードは登録しない
/// (充填時に拡張が Keychain から読む)
enum CredentialIdentityRegistrar {
    /// 直列化のための世代。sync は非同期 (state の取得と置換で中断する) なので、古いスナップショットが後から置換して
    /// 新しい保存を消さないよう、最新の呼び出しだけが置換する
    private static var generation = 0

    /// 資格情報を OS に登録する識別子。オリジンをそのまま URL 型で持たせ、http と https・別ポートを OS 側でも区別させる
    static func serviceIdentifier(credential: Credential) -> ASCredentialServiceIdentifier? {
        guard let scheme = credential.url.scheme?.lowercased(), !credential.host.isEmpty else {
            return nil
        }
        let port = credential.url.port.map { ":\($0)" } ?? ""
        return ASCredentialServiceIdentifier(identifier: "\(scheme)://\(credential.host)\(port)/", type: .URL)
    }

    /// ストアの全件で OS 側の一覧を置き換える。同じ内容で何度呼んでも同じ状態になる (追加ではなく置換)。
    /// システム設定で Tatami が自動入力プロバイダに選ばれていない間は何もしない (状態が無効の時の登録は捨てられる)
    static func sync(credentials: [Credential]) async {
        generation += 1
        let mine = generation
        guard await ASCredentialIdentityStore.shared.state().isEnabled, mine == generation else {
            return
        }
        let identities = credentials.compactMap { credential -> ASPasswordCredentialIdentity? in
            guard let serviceIdentifier = serviceIdentifier(credential: credential) else {
                return nil
            }
            return ASPasswordCredentialIdentity(serviceIdentifier: serviceIdentifier, user: credential.username, recordIdentifier: credential.id.uuidString)
        }
        do {
            try await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
        } catch {
            // 候補の登録は補助機能で、失敗しても Tatami 内の充填には影響しない。次の保存で再登録される
            NSLog("自動入力候補の登録に失敗: %@", "\(error)")
        }
    }

    /// ストアを読んで sync する。読めなかった時は OS 側の候補を消さずに (空で置換せずに) 中止する
    static func sync(store: any CredentialStore) async {
        let credentials: [Credential]
        do {
            credentials = try store.all()
        } catch {
            NSLog("自動入力候補の同期を中止 (資格情報を読めない): %@", "\(error)")
            return
        }
        await sync(credentials: credentials)
    }
}
