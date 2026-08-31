import Foundation
import Testing
@testable import Tatami

/// AddressInput.resolve の URL 解決規則を検証する
struct AddressInputTests {
    @Test func schemeURLIsUsedAsIs() {
        #expect(AddressInput.resolve(text: "https://example.com/path?x=1") == URL(string: "https://example.com/path?x=1"))
    }

    @Test func bareHostGetsHTTPSScheme() {
        #expect(AddressInput.resolve(text: " example.com ") == URL(string: "https://example.com"))
    }

    @Test func plainWordsBecomeSearchQuery() {
        #expect(AddressInput.resolve(text: "tmux split pane") == URL(string: "https://www.google.com/search?q=tmux%20split%20pane"))
    }

    @Test func aboutBlankIsKept() {
        #expect(AddressInput.resolve(text: "about:blank") == AddressInput.homeURL)
    }

    /// 空ページはアドレスバーを空にしてすぐ入力できるようにし、実ページは URL をそのまま表示する
    @Test func blankPageHasEmptyDisplayText() {
        #expect(AddressInput.displayText(url: AddressInput.homeURL) == "")
        #expect(AddressInput.displayText(url: URL(string: "https://example.com/path?x=1")!) == "https://example.com/path?x=1")
    }

    @Test func emailAddressBecomesSearchQuery() {
        #expect(AddressInput.resolve(text: "user@example.com") == URL(string: "https://www.google.com/search?q=user@example.com"))
    }

    @Test func localhostWithPortGetsHTTPScheme() {
        #expect(AddressInput.resolve(text: "localhost:3000/path") == URL(string: "http://localhost:3000/path"))
        #expect(AddressInput.resolve(text: "localhost") == URL(string: "http://localhost"))
    }

    @Test func ipAddressesGetHTTPScheme() {
        #expect(AddressInput.resolve(text: "127.0.0.1:8080") == URL(string: "http://127.0.0.1:8080"))
        #expect(AddressInput.resolve(text: "[::1]:3000") == URL(string: "http://[::1]:3000"))
    }

    @Test func searchURLKeepsConfiguredQueryParameters() {
        #expect(AddressInput.resolve(text: "tmux", searchURL: URL(string: "https://search.example/?p=&lang=ja")!) == URL(string: "https://search.example/?p=tmux&lang=ja"))
        #expect(AddressInput.resolve(text: "tmux", searchURL: URL(string: "https://search.example/?safe=1")!) == URL(string: "https://search.example/?safe=1&q=tmux"))
        #expect(AddressInput.resolve(text: "tmux", searchURL: URL(string: "https://search.example/?flag")!) == URL(string: "https://search.example/?flag&q=tmux"))
        #expect(AddressInput.resolve(text: "tmux", searchURL: URL(string: "https://search.example/?source=&q=")!) == URL(string: "https://search.example/?source=&q=tmux"))
        // 値の入った q も検索語で置き換える (2 つ目の q を足さない)
        #expect(AddressInput.resolve(text: "tmux", searchURL: URL(string: "https://search.example/?q=test&hl=ja")!) == URL(string: "https://search.example/?q=tmux&hl=ja"))
    }
}
