import Foundation

/// 訪問履歴とブックマーク。`~/Library/Application Support/Tatami/browsing.json` に保存する形そのもの
struct BrowsingData: Codable, Equatable {
    /// 1 回の訪問。同じ URL を続けて訪れた時は最新の 1 件だけを残す
    struct HistoryEntry: Codable, Equatable {
        let url: URL
        let title: String
        let visitedAt: Date
    }

    struct Bookmark: Codable, Equatable {
        let url: URL
        let title: String
        let addedAt: Date
    }

    /// アドレスバーの候補 1 件
    struct Suggestion: Equatable {
        let url: URL
        let title: String
        let isBookmark: Bool
    }

    /// 履歴の保存件数の上限。1 日 200 ページ × 1 か月分を目安にした。JSON を丸ごと読み書きする方式のため、
    /// これ以上増やすと起動時の読み込みと debounce 保存が目に見えて遅くなる (数 MB 規模)
    static let historyLimit = 6000
    /// アドレスバーに出す候補の上限。status line の下に重ねる一覧として一目で選べる量
    static let suggestionLimit = 8

    /// 新しい順
    private(set) var history: [HistoryEntry] = []
    /// 追加した順
    private(set) var bookmarks: [Bookmark] = []

    /// 訪問を記録する。同じ URL の古い記録は消して先頭に置き、上限を超えた分は末尾 (古い方) から捨てる
    mutating func recordVisit(url: URL, title: String, date: Date) {
        history.removeAll { $0.url == url }
        history.insert(HistoryEntry(url: url, title: title, visitedAt: date), at: 0)
        if history.count > BrowsingData.historyLimit {
            history.removeLast(history.count - BrowsingData.historyLimit)
        }
    }

    /// ブックマークを追加する。同じ URL があればタイトルだけ更新する
    mutating func addBookmark(url: URL, title: String, date: Date) {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks[index] = Bookmark(url: url, title: title, addedAt: bookmarks[index].addedAt)
        } else {
            bookmarks.append(Bookmark(url: url, title: title, addedAt: date))
        }
    }

    mutating func removeBookmark(url: URL) {
        bookmarks.removeAll { $0.url == url }
    }

    func isBookmarked(url: URL) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    /// アドレスバーの入力に対する候補。ブックマークを先に、次に履歴を新しい順に並べ、URL (スキームを除いた形) かタイトルが
    /// 入力で始まるものを返す。大文字小文字は区別しない
    func suggestions(prefix: String) -> [Suggestion] {
        let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return []
        }
        func matches(url: URL, title: String) -> Bool {
            BrowsingData.matchableForms(url: url).contains { $0.hasPrefix(needle) } || title.lowercased().hasPrefix(needle)
        }
        var seen: Set<URL> = []
        var result: [Suggestion] = []
        for bookmark in bookmarks where matches(url: bookmark.url, title: bookmark.title) {
            seen.insert(bookmark.url)
            result.append(Suggestion(url: bookmark.url, title: bookmark.title, isBookmark: true))
        }
        for entry in history where !seen.contains(entry.url) && matches(url: entry.url, title: entry.title) {
            seen.insert(entry.url)
            result.append(Suggestion(url: entry.url, title: entry.title, isBookmark: false))
        }
        return Array(result.prefix(BrowsingData.suggestionLimit))
    }

    /// `https://www.example.com/path` に対して `https://www.example.com/path` / `www.example.com/path` / `example.com/path` を前方一致の対象にする
    /// (スキームや `www.` を打たずに候補を出せるように)
    private static func matchableForms(url: URL) -> [String] {
        let full = url.absoluteString.lowercased()
        var forms = [full]
        if let scheme = url.scheme {
            let withoutScheme = String(full.dropFirst(scheme.count + "://".count))
            forms.append(withoutScheme)
            if withoutScheme.hasPrefix("www.") {
                forms.append(String(withoutScheme.dropFirst("www.".count)))
            }
        }
        return forms
    }
}

/// browsing.json の読み書き
enum BrowsingStore {
    static let defaultFileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Tatami/browsing.json")

    static func save(data: BrowsingData, fileURL: URL = defaultFileURL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(data).write(to: fileURL, options: .atomic)
    }

    /// 起動時の読み込み。壊れていれば空から始める (履歴は失っても致命的でない。ログに出す)
    static func loadOrEmpty() -> BrowsingData {
        do {
            return try load()
        } catch {
            NSLog("履歴の読み込みに失敗 (空から始める): %@", String(describing: error))
            return BrowsingData()
        }
    }

    /// ファイルが無ければ空のデータ。壊れていればエラー
    static func load(fileURL: URL = defaultFileURL) throws -> BrowsingData {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return BrowsingData()
        }
        return try JSONDecoder().decode(BrowsingData.self, from: Data(contentsOf: fileURL))
    }
}
