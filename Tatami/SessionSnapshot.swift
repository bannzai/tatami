import Foundation

/// 保存・復元するセッションの内容 (ウィンドウ一覧・各ウィンドウのペインツリー・各ペインの URL・名前)。
/// `~/Library/Application Support/Tatami/sessions/<name>.json` に JSON で保存する形そのもの
struct SessionSnapshot: Codable, Equatable {
    /// 1 つのウィンドウ (tmux の window) の内容
    struct Window: Codable, Equatable {
        /// 1 ペインの識別子と表示中の URL。ペインツリーの葉と 1 対 1
        struct Pane: Codable, Equatable {
            let id: PaneID
            let url: URL
        }

        let paneTree: PaneTree
        let panes: [Pane]
        /// rename-window で付けた名前。nil なら automatic-rename
        let renamedName: String?
    }

    let name: String
    let windows: [Window]
    let currentWindowIndex: Int
}

/// セッションファイルの読み書き。ファイル名はセッション名 + `.json`
enum SessionStore {
    /// 既定の保存先。サンドボックス外のため Application Support 直下にアプリ名のディレクトリを作る
    static let defaultDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Tatami/sessions", directoryHint: .isDirectory)

    static func fileURL(name: String, directoryURL: URL = defaultDirectoryURL) -> URL {
        directoryURL.appending(path: "\(name).json")
    }

    /// 書き込みはアトミック (一時ファイルに書いてから置き換える) にして、書き込み中のクラッシュで直前の状態を失わないようにする
    static func save(snapshot: SessionSnapshot, directoryURL: URL = defaultDirectoryURL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL(name: snapshot.name, directoryURL: directoryURL), options: .atomic)
    }

    /// ファイルが無ければ nil。壊れたファイルはエラーとして投げ、呼び出し側が新規セッションで始める
    static func load(name: String, directoryURL: URL = defaultDirectoryURL) throws -> SessionSnapshot? {
        let url = fileURL(name: name, directoryURL: directoryURL)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        return try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: url))
    }

    /// 保存済みのセッション名の一覧 (名前順)
    static func sessionNames(directoryURL: URL = defaultDirectoryURL) -> [String] {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        return fileURLs.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// セッション名の変更 = ファイル名の変更。同名があれば上書きせずエラーにする
    static func rename(name: String, newName: String, directoryURL: URL = defaultDirectoryURL) throws {
        try FileManager.default.moveItem(at: fileURL(name: name, directoryURL: directoryURL), to: fileURL(name: newName, directoryURL: directoryURL))
    }
}
