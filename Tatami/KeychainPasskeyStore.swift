import Foundation
import Security

/// Passkey を Keychain に保存するストア。属性の設計は KeychainCredentialStore (ADR 0004) と同じで、service だけを分ける
/// (資格情報の列挙・CSV の入出力に Passkey が混ざらないようにする)
final class KeychainPasskeyStore: PasskeyStore {
    static let service = "com.bannzai.Tatami.passkeys"
    private let accessGroup: String?

    init(accessGroup: String? = KeychainCredentialStore.sharedAccessGroup) {
        self.accessGroup = accessGroup
    }

    func all() throws -> [Passkey] {
        var listQuery = baseQuery()
        listQuery[kSecMatchLimit as String] = kSecMatchLimitAll
        listQuery[kSecReturnAttributes as String] = true
        var listResult: CFTypeRef?
        let listStatus = SecItemCopyMatching(listQuery as CFDictionary, &listResult)
        if listStatus == errSecItemNotFound {
            return []
        }
        guard listStatus == errSecSuccess, let attributes = listResult as? [[String: Any]] else {
            throw KeychainError(status: listStatus)
        }
        let decoder = JSONDecoder()
        // ファイルベースのキーチェーンは複数件の kSecReturnData を拒むため (KeychainCredentialStore と同じ)、1 件ずつ読む
        return try attributes.compactMap { $0[kSecAttrAccount as String] as? String }.map { account -> Passkey in
            var query = baseQuery()
            query[kSecAttrAccount as String] = account
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                throw KeychainError(status: status)
            }
            return try decoder.decode(Passkey.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func save(passkey: Passkey) throws {
        let data = try JSONEncoder().encode(passkey)
        var query = baseQuery()
        query[kSecAttrAccount as String] = passkey.id.uuidString
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: passkey.rpId]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }
        var item = query
        item.merge(attributes) { _, new in new }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let accessGroup {
            item[kSecAttrAccessGroup as String] = accessGroup
        }
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

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainPasskeyStore.service,
            kSecAttrSynchronizable as String: accessGroup != nil,
        ]
    }
}
