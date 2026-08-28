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
    /// アプリと Credential Provider Extension (#17) が共有する access group。Debug (ad-hoc 署名) では entitlement が効かないため使わない
    static let sharedAccessGroup: String? = {
        #if DEBUG
        return nil
        #else
        return "TQPN82UBBY.com.bannzai.Tatami.shared"
        #endif
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
        return items.compactMap { try? decoder.decode(Credential.self, from: $0) }.sorted { $0.updatedAt > $1.updatedAt }
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
