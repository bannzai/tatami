import Foundation
import Security

/// Keychain の操作で起きたエラー。OSStatus をそのまま表示する
struct KeychainError: Error, CustomStringConvertible, Equatable {
    let status: OSStatus

    var description: String {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "")"
    }
}

/// Keychain に資格情報を保存するストア。アイテムの属性の設計と理由は documents/adr/0004-keychain-credential-store.md
final class KeychainCredentialStore: CredentialStore {
    /// 全アイテムに共通の service。Tatami の資格情報だけを列挙するための識別子
    static let service = "com.bannzai.Tatami.credentials"
    /// アプリと Credential Provider Extension (#17) が共有する access group。署名に含まれた `keychain-access-groups` の先頭の値を実行時に読む
    /// (Team ID の prefix は署名した Team で決まるため、固定値にすると別の Team で署名した時に errSecMissingEntitlement になる)。
    /// entitlement が無い署名 (Debug の ad-hoc 等) では nil で、access group を指定しない
    static let sharedAccessGroup: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String] else {
            return nil
        }
        return groups.first { $0.hasSuffix(".com.bannzai.Tatami.shared") }
    }()

    private let accessGroup: String?

    init(accessGroup: String? = KeychainCredentialStore.sharedAccessGroup) {
        self.accessGroup = accessGroup
    }

    func all() throws -> [Credential] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let items = result as? [Data] else {
            throw KeychainError(status: status)
        }
        let decoder = JSONDecoder()
        // 復号できない項目 (旧スキーマ・破損) を黙って捨てると保存済みのパスワードが消えたように見えるため、エラーとして伝える
        return try items.map { try decoder.decode(Credential.self, from: $0) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(credential: Credential) throws {
        let data = try JSONEncoder().encode(credential)
        var query = baseQuery()
        query[kSecAttrAccount as String] = credential.id.uuidString
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: credential.host,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }
        var item = query
        item.merge(attributes) { _, new in new }
        // ロック中の Mac では読めなくてよい (充填はアンロック中にしか行わない) が、初回アンロック後は常に読める必要がある
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func delete(id: UUID) throws {
        var query = baseQuery()
        query[kSecAttrAccount as String] = id.uuidString
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    func credentials(host: String) throws -> [Credential] {
        try all().filter { $0.host == host.lowercased() }
    }

    /// 全操作に共通する属性。synchronizable を明示しないと同期アイテムが検索から漏れるため、検索にも kSecAttrSynchronizable を付ける
    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainCredentialStore.service,
            kSecAttrSynchronizable as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
