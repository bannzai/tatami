import Foundation
import Testing
@testable import Tatami

/// 履歴・ブックマークの記録と、アドレスバーの候補の抽出を検証する
struct BrowsingDataTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func visitsAreDedupedNewestFirstAndCapped() {
        var data = BrowsingData()
        data.recordVisit(url: URL(string: "https://a.example/")!, title: "A", date: base)
        data.recordVisit(url: URL(string: "https://b.example/")!, title: "B", date: base.addingTimeInterval(1))
        data.recordVisit(url: URL(string: "https://a.example/")!, title: "A2", date: base.addingTimeInterval(2))
        #expect(data.history.map(\.title) == ["A2", "B"])
        for index in 0..<(BrowsingData.historyLimit + 10) {
            data.recordVisit(url: URL(string: "https://n.example/\(index)")!, title: "\(index)", date: base)
        }
        #expect(data.history.count == BrowsingData.historyLimit)
        #expect(data.history.first?.title == "\(BrowsingData.historyLimit + 9)")
    }

    @Test func bookmarksAreUniqueByURL() {
        var data = BrowsingData()
        let url = URL(string: "https://a.example/")!
        data.addBookmark(url: url, title: "A", date: base)
        data.addBookmark(url: url, title: "A renamed", date: base.addingTimeInterval(5))
        #expect(data.bookmarks.count == 1)
        #expect(data.bookmarks[0].title == "A renamed")
        #expect(data.bookmarks[0].addedAt == base)
        #expect(data.isBookmarked(url: url))
        data.removeBookmark(url: url)
        #expect(data.bookmarks.isEmpty)
    }

    @Test func suggestionsMatchPrefixOfURLFormsAndTitle() {
        var data = BrowsingData()
        data.recordVisit(url: URL(string: "https://www.example.com/docs")!, title: "Example Docs", date: base)
        data.recordVisit(url: URL(string: "https://other.example/")!, title: "Other", date: base.addingTimeInterval(1))
        data.addBookmark(url: URL(string: "https://example.org/")!, title: "Org", date: base)
        #expect(data.suggestions(prefix: "example").map(\.url.absoluteString) == ["https://example.org/", "https://www.example.com/docs"])
        #expect(data.suggestions(prefix: "www.ex").map(\.title) == ["Example Docs"])
        #expect(data.suggestions(prefix: "EXAMPLE D").map(\.title) == ["Example Docs"])
        #expect(data.suggestions(prefix: "https://oth").map(\.title) == ["Other"])
        #expect(data.suggestions(prefix: "   ").isEmpty)
        #expect(data.suggestions(prefix: "zzz").isEmpty)
        #expect(data.suggestions(prefix: "example")[0].isBookmark)
    }

    @Test func suggestionsAreLimited() {
        var data = BrowsingData()
        for index in 0..<20 {
            data.recordVisit(url: URL(string: "https://site\(index).example/")!, title: "Site \(index)", date: base.addingTimeInterval(Double(index)))
        }
        #expect(data.suggestions(prefix: "site").count == BrowsingData.suggestionLimit)
    }

    @Test func storeRoundTrips() throws {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "tatami-browsing-\(UUID().uuidString)/browsing.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        #expect(try BrowsingStore.load(fileURL: fileURL) == BrowsingData())
        var data = BrowsingData()
        data.recordVisit(url: URL(string: "https://a.example/")!, title: "A", date: base)
        data.addBookmark(url: URL(string: "https://b.example/")!, title: "B", date: base)
        try BrowsingStore.save(data: data, fileURL: fileURL)
        #expect(try BrowsingStore.load(fileURL: fileURL) == data)
    }
}
