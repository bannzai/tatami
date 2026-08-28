import Foundation
import Testing
@testable import Tatami

/// CredentialStore の契約 (追加・更新・削除・ホスト検索の冪等性) をメモリ実装で検証する。Keychain 実装は同じ契約を守る前提で CI では触れない
struct CredentialStoreTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func makeCredential(id: UUID = UUID(), url: String, username: String, date: Date) -> Credential {
        Credential(id: id, url: URL(string: url)!, username: username, password: "dummy-password", note: "", updatedAt: date)
    }

    @Test func saveIsIdempotentAndUpdatesById() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()
        let credential = makeCredential(id: id, url: "https://example.com/login", username: "alice", date: base)
        try store.save(credential: credential)
        try store.save(credential: credential)
        #expect(try store.all() == [credential])
        var updated = credential
        updated.password = "new-dummy-password"
        updated.updatedAt = base.addingTimeInterval(10)
        try store.save(credential: updated)
        #expect(try store.all() == [updated])
    }

    @Test func deleteIsIdempotent() throws {
        let store = InMemoryCredentialStore()
        let credential = makeCredential(url: "https://example.com/", username: "alice", date: base)
        try store.save(credential: credential)
        try store.delete(id: credential.id)
        try store.delete(id: credential.id)
        try store.delete(id: UUID())
        #expect(try store.all().isEmpty)
    }

    @Test func hostSearchIsExactAndCaseInsensitiveAndNewestFirst() throws {
        let older = makeCredential(url: "https://Example.com/login", username: "alice", date: base)
        let newer = makeCredential(url: "https://example.com/", username: "bob", date: base.addingTimeInterval(5))
        let sub = makeCredential(url: "https://mail.example.com/", username: "carol", date: base.addingTimeInterval(-5))
        let store = InMemoryCredentialStore(credentials: [older, sub, newer])
        #expect(try store.credentials(host: "EXAMPLE.com").map(\.username) == ["bob", "alice"])
        #expect(try store.credentials(host: "mail.example.com").map(\.username) == ["carol"])
        #expect(try store.credentials(host: "other.example").isEmpty)
        #expect(try store.all().map(\.username) == ["bob", "alice", "carol"])
    }

    @Test func hostOfURLWithoutHostIsEmpty() {
        let credential = makeCredential(url: "about:blank", username: "x", date: base)
        #expect(credential.host.isEmpty)
    }
}
