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

/// セッションファイルの読み書きで起きるエラー。メッセージは加工せずそのまま表示する
enum SessionStoreError: Error, CustomStringConvertible {
    /// パス区切りや `..` を含むなど、ファイル名として使えないセッション名
    case invalidName(String)
    /// JSON としては読めたが、ペインツリーの内部参照や現在ウィンドウの添字が不整合
    case inconsistentSnapshot(String)

    var description: String {
        switch self {
        case .invalidName(let name):
            return "セッション名に使えない文字を含む: \(name)"
        case .inconsistentSnapshot(let name):
            return "セッションファイルの内容が不整合: \(name)"
        }
    }
}

/// セッションファイルの読み書き。ファイル名はセッション名 + `.json`
enum SessionStore {
    /// セッション名は単一のファイル名にする。`/` や `..` を含むと sessions ディレクトリの外に書いてしまうため受け付けない
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func validated(name: String) throws -> String {
        guard isValidName(name) else {
            throw SessionStoreError.invalidName(name)
        }
        return name
    }
    /// 既定の保存先。サンドボックス外のため Application Support 直下にアプリ名のディレクトリを作る
    static let defaultDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Tatami/sessions", directoryHint: .isDirectory)

    static func fileURL(name: String, directoryURL: URL = defaultDirectoryURL) -> URL {
        directoryURL.appending(path: "\(name).json")
    }

    /// 書き込みはアトミック (一時ファイルに書いてから置き換える) にして、書き込み中のクラッシュで直前の状態を失わないようにする
    static func save(snapshot: SessionSnapshot, directoryURL: URL = defaultDirectoryURL) throws {
        _ = try validated(name: snapshot.name)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL(name: snapshot.name, directoryURL: directoryURL), options: .atomic)
    }

    /// ファイルが無ければ nil。壊れたファイルはエラーとして投げ、呼び出し側が新規セッションで始める
    static func load(name: String, directoryURL: URL = defaultDirectoryURL) throws -> SessionSnapshot? {
        let url = fileURL(name: try validated(name: name), directoryURL: directoryURL)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: url))
        // JSON として正しくても内部参照が壊れていると復元時にクラッシュして起動できなくなるため、ここで弾いて新規セッションにフォールバックさせる
        guard snapshot.windows.allSatisfy(\.paneTree.isConsistent),
              snapshot.windows.isEmpty || snapshot.windows.indices.contains(snapshot.currentWindowIndex) else {
            throw SessionStoreError.inconsistentSnapshot(name)
        }
        return snapshot
    }

    /// 保存済みのセッション名の一覧 (名前順)。ディレクトリが無ければ空。読めない (権限・I/O エラー) 時は空にせずエラーを投げる
    static func sessionNames(directoryURL: URL = defaultDirectoryURL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directoryURL.path(percentEncoded: false)) else {
            return []
        }
        let fileURLs = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        return fileURLs.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// その名前の保存ファイルがあるか
    static func fileExists(name: String, directoryURL: URL = defaultDirectoryURL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(name: name, directoryURL: directoryURL).path(percentEncoded: false))
    }

    /// セッション名の変更 = ファイル名の変更。同名があれば上書きせずエラーにする
    static func rename(name: String, newName: String, directoryURL: URL = defaultDirectoryURL) throws {
        try FileManager.default.moveItem(
            at: fileURL(name: try validated(name: name), directoryURL: directoryURL),
            to: fileURL(name: try validated(name: newName), directoryURL: directoryURL)
        )
    }
}
