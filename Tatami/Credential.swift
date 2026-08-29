import Foundation

/// Password Manager が保存する 1 件の資格情報。1 つのサイト (URL) に対して複数の資格情報を持てる (要件の SSOT: https://github.com/bannzai/IdeaMemo/issues/191#issuecomment-5449063461 )
struct Credential: Codable, Equatable, Identifiable, Sendable {
    /// ストア内で一意。Keychain アイテムの account 属性にもこの値を使う
    let id: UUID
    /// ログインページの URL。候補の絞り込みはホスト名で行う
    var url: URL
    var username: String
    var password: String
    var note: String
    /// 追加または更新した日時
    var updatedAt: Date

    /// 候補の絞り込みに使うホスト名 (小文字)。URL にホストが無ければ空文字
    var host: String {
        url.host()?.lowercased() ?? ""
    }
}

/// 資格情報の保存先。Keychain 実装と、ユニットテスト用のメモリ実装を差し替えられるようにする (CI は Keychain に触れない)
protocol CredentialStore {
    /// 全件 (順序は更新日時の新しい順)
    func all() throws -> [Credential]
    /// 追加または更新 (id が同じなら上書き)。同じ内容で何度呼んでも 1 件のまま
    func save(credential: Credential) throws
    /// 削除。無い id は何もしない
    func delete(id: UUID) throws
    /// ホスト名が一致する資格情報 (更新日時の新しい順)。サブドメインや eTLD+1 の一致規則はフォーム充填 (#14) 側で扱い、ここは完全一致
    func credentials(host: String) throws -> [Credential]
}

/// ユニットテスト用のメモリ実装
final class InMemoryCredentialStore: CredentialStore {
    private var storage: [UUID: Credential] = [:]

    init(credentials: [Credential] = []) {
        for credential in credentials {
            storage[credential.id] = credential
        }
    }

    func all() throws -> [Credential] {
        storage.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(credential: Credential) throws {
        storage[credential.id] = credential
    }

    func delete(id: UUID) throws {
        storage[id] = nil
    }

    func credentials(host: String) throws -> [Credential] {
        try all().filter { $0.host == host.lowercased() }
    }
}
