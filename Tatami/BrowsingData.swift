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
        /// 読み込み中にブックマークしてタイトルが未確定 (ホスト名を仮に入れた) か。確定後の更新で置き換える対象を、
        /// 正式なタイトルがホスト名と同じページと区別するために持つ
        var isTitleProvisional = false

        // isTitleProvisional は後から加えたため、旧版で保存したファイル (キーなし) を読めるよう decodeIfPresent にしている
        init(url: URL, title: String, addedAt: Date, isTitleProvisional: Bool = false) {
            self.url = url
            self.title = title
            self.addedAt = addedAt
            self.isTitleProvisional = isTitleProvisional
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decode(URL.self, forKey: .url)
            title = try container.decode(String.self, forKey: .title)
            addedAt = try container.decode(Date.self, forKey: .addedAt)
            isTitleProvisional = try container.decodeIfPresent(Bool.self, forKey: .isTitleProvisional) ?? false
        }
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

    /// 履歴のタイトルだけを更新する (順序と訪問日時は変えない)。該当する URL が無ければ false
    mutating func updateTitle(url: URL, title: String) -> Bool {
        var changed = false
        if let index = history.firstIndex(where: { $0.url == url }), history[index].title != title {
            history[index] = HistoryEntry(url: url, title: title, visitedAt: history[index].visitedAt)
            changed = true
        }
        // 読み込み中に付けたブックマークは仮の名前を持つため、その場合だけ確定したタイトルに揃える。
        // 未読件数などで変わる動的なタイトルで、確定済みの名前を書き換えない
        if let index = bookmarks.firstIndex(where: { $0.url == url }), bookmarks[index].isTitleProvisional {
            bookmarks[index] = Bookmark(url: url, title: title, addedAt: bookmarks[index].addedAt)
            changed = true
        }
        return changed
    }

    /// ブックマークを追加する。同じ URL があればタイトルだけ更新する
    mutating func addBookmark(url: URL, title: String, date: Date, isTitleProvisional: Bool = false) {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks[index] = Bookmark(url: url, title: title, addedAt: bookmarks[index].addedAt, isTitleProvisional: isTitleProvisional)
        } else {
            bookmarks.append(Bookmark(url: url, title: title, addedAt: date, isTitleProvisional: isTitleProvisional))
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
    /// 起動時の読み込みの結果。isWritable が false なら元のファイルを守るため自動保存を止める
    struct LoadResult {
        let data: BrowsingData
        let isWritable: Bool
        /// 読み込めなかった時の説明 (status line に出す)
        let problem: String?
    }

    /// 起動時の読み込み。壊れていれば退避してから空で始める。退避もできなければ、元のファイルを空のデータで上書きしないよう保存を止める
    static func loadOrEmpty(fileURL: URL = defaultFileURL) -> LoadResult {
        do {
            return LoadResult(data: try load(fileURL: fileURL), isWritable: true, problem: nil)
        } catch {
            let backupURL = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
                NSLog("履歴の読み込みに失敗 (%@ に退避して空から始める): %@", backupURL.path(percentEncoded: false), String(describing: error))
                return LoadResult(data: BrowsingData(), isWritable: true, problem: "履歴を読めなかったため \(backupURL.lastPathComponent) に退避した")
            } catch let moveError {
                NSLog("履歴の読み込みと退避に失敗 (保存を止める): %@ / %@", String(describing: error), String(describing: moveError))
                return LoadResult(data: BrowsingData(), isWritable: false, problem: "履歴を読めず退避もできないため、履歴・ブックマークを保存しない: \(error)")
            }
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
