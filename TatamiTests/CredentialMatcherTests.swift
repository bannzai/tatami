import Foundation
import Testing
@testable import Tatami

/// サブドメイン・eTLD+1 (Public Suffix List)・スキーム・ポートの一致規則を検証する
struct CredentialMatcherTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)
    /// テスト用の最小のリスト (同梱の実物と同じ文法)
    private let rules = PublicSuffixList.Rules(text: """
        // ===BEGIN ICANN DOMAINS===
        com
        jp
        co.jp
        *.ck
        !www.ck
        // ===BEGIN PRIVATE DOMAINS===
        github.io
        """)

    private func makeCredential(url: String, username: String, date: Date) -> Credential {
        Credential(id: UUID(), url: URL(string: url)!, username: username, password: "dummy-password", note: "", updatedAt: date)
    }

    private func matches(_ credential: String, _ page: String) -> Bool {
        CredentialMatcher.matches(credentialURL: URL(string: credential)!, pageURL: URL(string: page)!, rules: rules)
    }

    @Test func registrableDomainFollowsPublicSuffixList() {
        #expect(CredentialMatcher.registrableDomain(host: "accounts.example.com", rules: rules) == "example.com")
        #expect(CredentialMatcher.registrableDomain(host: "www.example.co.jp", rules: rules) == "example.co.jp")
        #expect(CredentialMatcher.registrableDomain(host: "alice.github.io", rules: rules) == "alice.github.io")
        #expect(CredentialMatcher.registrableDomain(host: "github.io", rules: rules) == nil)
        #expect(CredentialMatcher.registrableDomain(host: "a.b.ck", rules: rules) == "a.b.ck")
        #expect(CredentialMatcher.registrableDomain(host: "www.ck", rules: rules) == "www.ck")
        #expect(CredentialMatcher.registrableDomain(host: "example.unknowntld", rules: rules) == nil)
        #expect(CredentialMatcher.registrableDomain(host: "localhost", rules: rules) == nil)
        #expect(CredentialMatcher.registrableDomain(host: "127.0.0.1", rules: rules) == nil)
    }

    @Test func idnRulesAndHostsAreComparedInASCIIForm() {
        let idnRules = PublicSuffixList.Rules(text: "中国\ncom")
        #expect(idnRules.rules.contains("xn--fiqs8s"))
        #expect(CredentialMatcher.registrableDomain(host: "accounts.example.xn--fiqs8s", rules: idnRules) == "example.xn--fiqs8s")
        #expect(CredentialMatcher.registrableDomain(host: "login.example.中国", rules: idnRules) == "example.xn--fiqs8s")
    }

    @Test func bundledListIsLoaded() {
        #expect(PublicSuffixList.bundled.rules.contains("co.jp"))
        #expect(PublicSuffixList.bundled.rules.contains("github.io"))
        #expect(CredentialMatcher.registrableDomain(host: "alice.github.io") == "alice.github.io")
    }

    @Test func matchesSameOriginAndSameRegistrableDomain() {
        #expect(matches("https://example.com/", "https://example.com/login"))
        #expect(matches("https://accounts.example.com/", "https://example.com/"))
        #expect(matches("https://example.com/", "https://login.example.com/"))
        #expect(matches("https://a.example.co.jp/", "https://b.example.co.jp/"))
        #expect(!matches("https://example.com/", "https://example.org/"))
        #expect(!matches("https://notexample.com/", "https://example.com/"))
        #expect(!matches("https://a.co.jp/", "https://b.co.jp/"))
        #expect(!matches("https://alice.github.io/", "https://evil.github.io/"))
        #expect(!matches("https://a.example.unknowntld/", "https://b.example.unknowntld/"))
        #expect(matches("http://localhost:8765/", "http://localhost:8765/login"))
        #expect(!matches("http://localhost/", "http://localhost.example.com/"))
        #expect(matches("http://127.0.0.1/", "http://127.0.0.1/"))
        #expect(!matches("http://127.0.0.1/", "http://1.0.0.1/"))
    }

    @Test func httpsCredentialsAreNotOfferedToHTTPOrOtherPorts() {
        #expect(!matches("https://example.com/", "http://example.com/"))
        #expect(matches("http://example.com/", "https://example.com/"))
        #expect(!matches("https://example.com/", "https://example.com:8443/"))
        #expect(matches("https://example.com:443/", "https://example.com/"))
        #expect(!matches("https://example.com/", "ftp://example.com/"))
    }

    @Test func candidatesPutExactHostFirstThenNewest() {
        let credentials = [
            makeCredential(url: "https://accounts.example.com/", username: "sub-old", date: base),
            makeCredential(url: "https://example.com/", username: "exact-old", date: base),
            makeCredential(url: "https://example.com/login", username: "exact-new", date: base.addingTimeInterval(10)),
            makeCredential(url: "https://example.org/", username: "other", date: base.addingTimeInterval(20)),
            makeCredential(url: "https://mail.example.com/", username: "sub-new", date: base.addingTimeInterval(5)),
            makeCredential(url: "http://example.com/", username: "http-only", date: base.addingTimeInterval(30)),
        ]
        let page = URL(string: "https://example.com/")!
        #expect(CredentialMatcher.candidates(credentials: credentials, pageURL: page, rules: rules).map(\.username) == ["exact-new", "exact-old", "http-only", "sub-new", "sub-old"])
        #expect(CredentialMatcher.candidates(credentials: credentials, pageURL: URL(string: "http://example.com/")!, rules: rules).map(\.username) == ["http-only"])
        #expect(CredentialMatcher.candidates(credentials: credentials, pageURL: URL(string: "https://unknown.test/")!, rules: rules).isEmpty)
    }

    @Test func sameOriginRequiresExactSchemeHostAndPort() {
        let credential = URL(string: "https://accounts.example.com/login")!
        #expect(CredentialMatcher.sameOrigin(credentialURL: credential, pageURL: URL(string: "https://accounts.example.com:443/frame")!))
        #expect(!CredentialMatcher.sameOrigin(credentialURL: credential, pageURL: URL(string: "https://evil.example.com/")!))
        #expect(!CredentialMatcher.sameOrigin(credentialURL: credential, pageURL: URL(string: "http://accounts.example.com/")!))
        #expect(!CredentialMatcher.sameOrigin(credentialURL: credential, pageURL: URL(string: "https://accounts.example.com:8443/")!))
    }

    @Test func idnHostsMatchAcrossUnicodeAndPunycode() {
        let unicode = URL(string: "https://日本語.example/login")!
        let punycode = URL(string: "https://xn--wgv71a119e.example/")!
        #expect(CredentialMatcher.host(url: unicode) == "xn--wgv71a119e.example")
        #expect(CredentialMatcher.sameOrigin(credentialURL: unicode, pageURL: punycode))
        #expect(CredentialMatcher.matches(credentialURL: unicode, pageURL: punycode))
    }
}
