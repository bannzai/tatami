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

    @Test func updateTitleKeepsOrderAndVisitDate() {
        var data = BrowsingData()
        data.recordVisit(url: URL(string: "https://a.example/")!, title: "A", date: base)
        data.recordVisit(url: URL(string: "https://b.example/")!, title: "B", date: base.addingTimeInterval(1))
        let updated = data.updateTitle(url: URL(string: "https://a.example/")!, title: "A (3)")
        #expect(updated)
        #expect(data.history.map(\.title) == ["B", "A (3)"])
        #expect(data.history[1].visitedAt == base)
        let unchanged = data.updateTitle(url: URL(string: "https://a.example/")!, title: "A (3)")
        #expect(!unchanged)
        let missing = data.updateTitle(url: URL(string: "https://zzz.example/")!, title: "Z")
        #expect(!missing)
    }

    @Test func updateTitleAlsoRenamesBookmark() {
        var data = BrowsingData()
        let url = URL(string: "https://a.example/")!
        data.addBookmark(url: url, title: "a.example", date: base, isTitleProvisional: true)
        let renamed = data.updateTitle(url: url, title: "A")
        #expect(renamed)
        #expect(data.bookmarks[0].title == "A")
        // 確定済みの名前は動的なタイトル (未読件数等) で書き換えない
        let dynamic = data.updateTitle(url: url, title: "(3) A")
        #expect(!dynamic)
        #expect(data.bookmarks[0].title == "A")
    }

    @Test func corruptedFileIsBackedUpInsteadOfOverwritten() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(path: "tatami-browsing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileURL = directoryURL.appending(path: "browsing.json")
        try Data("not json".utf8).write(to: fileURL)
        let loaded = BrowsingStore.loadOrEmpty(fileURL: fileURL)
        #expect(loaded.data == BrowsingData())
        #expect(loaded.isWritable)
        let remaining = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        #expect(remaining.count == 1)
        #expect(remaining[0].hasPrefix("browsing.json.corrupt-"))
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

    @Test func provisionalBookmarkTitleIsReplacedOnlyWhileProvisional() {
        var data = BrowsingData()
        let base = Date(timeIntervalSince1970: 1_000)
        let url = URL(string: "https://example.com/")!
        data.addBookmark(url: url, title: "example.com", date: base, isTitleProvisional: true)
        let replaced = data.updateTitle(url: url, title: "Example Home")
        #expect(replaced)
        #expect(data.bookmarks[0].title == "Example Home")
        #expect(!data.bookmarks[0].isTitleProvisional)
        // 確定後は動的なタイトルで書き換えない (正式なタイトルがホスト名と同じ場合も同様)
        let changedAfterFinal = data.updateTitle(url: url, title: "(3) Example Home")
        #expect(!changedAfterFinal)
        data.addBookmark(url: url, title: "example.com", date: base)
        let changedHostTitle = data.updateTitle(url: url, title: "(1) example.com")
        #expect(!changedHostTitle)
        #expect(data.bookmarks[0].title == "example.com")
    }
}
