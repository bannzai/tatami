import Foundation
import Testing
@testable import Tatami

/// サブドメイン・eTLD+1 の一致規則を検証する
struct CredentialMatcherTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func makeCredential(url: String, username: String, date: Date) -> Credential {
        Credential(id: UUID(), url: URL(string: url)!, username: username, password: "dummy-password", note: "", updatedAt: date)
    }

    @Test func registrableDomainHandlesTwoLevelSuffixes() {
        #expect(CredentialMatcher.registrableDomain(host: "accounts.example.com") == "example.com")
        #expect(CredentialMatcher.registrableDomain(host: "www.example.co.jp") == "example.co.jp")
        #expect(CredentialMatcher.registrableDomain(host: "example.co.jp") == "example.co.jp")
        #expect(CredentialMatcher.registrableDomain(host: "EXAMPLE.COM") == "example.com")
        #expect(CredentialMatcher.registrableDomain(host: "localhost") == "localhost")
        #expect(CredentialMatcher.registrableDomain(host: "127.0.0.1") == "127.0.0.1")
    }

    @Test func matchesExactSubdomainAndSameRegistrableDomain() {
        #expect(CredentialMatcher.matches(credentialHost: "example.com", pageHost: "example.com"))
        #expect(CredentialMatcher.matches(credentialHost: "accounts.example.com", pageHost: "example.com"))
        #expect(CredentialMatcher.matches(credentialHost: "example.com", pageHost: "login.example.com"))
        #expect(CredentialMatcher.matches(credentialHost: "a.example.co.jp", pageHost: "b.example.co.jp"))
        #expect(!CredentialMatcher.matches(credentialHost: "example.com", pageHost: "example.org"))
        #expect(!CredentialMatcher.matches(credentialHost: "notexample.com", pageHost: "example.com"))
        #expect(!CredentialMatcher.matches(credentialHost: "a.co.jp", pageHost: "b.co.jp"))
        #expect(CredentialMatcher.matches(credentialHost: "localhost", pageHost: "localhost"))
        #expect(!CredentialMatcher.matches(credentialHost: "localhost", pageHost: "localhost.example.com"))
        #expect(CredentialMatcher.matches(credentialHost: "127.0.0.1", pageHost: "127.0.0.1"))
        #expect(!CredentialMatcher.matches(credentialHost: "127.0.0.1", pageHost: "1.0.0.1"))
        #expect(!CredentialMatcher.matches(credentialHost: "", pageHost: "example.com"))
    }

    @Test func candidatesPutExactHostFirstThenNewest() {
        let credentials = [
            makeCredential(url: "https://accounts.example.com/", username: "sub-old", date: base),
            makeCredential(url: "https://example.com/", username: "exact-old", date: base),
            makeCredential(url: "https://example.com/login", username: "exact-new", date: base.addingTimeInterval(10)),
            makeCredential(url: "https://example.org/", username: "other", date: base.addingTimeInterval(20)),
            makeCredential(url: "https://mail.example.com/", username: "sub-new", date: base.addingTimeInterval(5)),
        ]
        #expect(CredentialMatcher.candidates(credentials: credentials, pageHost: "example.com").map(\.username) == ["exact-new", "exact-old", "sub-new", "sub-old"])
        #expect(CredentialMatcher.candidates(credentials: credentials, pageHost: "example.org").map(\.username) == ["other"])
        #expect(CredentialMatcher.candidates(credentials: credentials, pageHost: "unknown.test").isEmpty)
    }
}
