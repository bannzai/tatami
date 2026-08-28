import Foundation
import Observation

/// アプリ全体で 1 つの tatami.conf の内容。macOS のウィンドウ (BrowserWindowModel) が複数あっても設定は共有し、
/// source-file での再読込を全ウィンドウに反映する
@MainActor
@Observable
final class TatamiConfigStore {
    static let shared = TatamiConfigStore()

    /// 現在の設定。起動時に既定ファイルを読んだ結果から始まる
    private(set) var config: TatamiConfig
    /// 直近の読み込みで解釈できなかった行
    private(set) var loadErrors: [TatamiConfigError]

    private init() {
        let loaded = TatamiConfigLoader.load()
        config = loaded.config
        loadErrors = loaded.errors
    }

    /// コマンドプロンプトからの 1 行 (`set` / `bind` / `unbind` / `source-file`) を現在の設定に適用する。設定ファイルと同じ解釈を使う
    func apply(line: String) -> [TatamiConfigError] {
        var updated = config
        let errors = TatamiConfigParser.apply(
            text: line,
            config: &updated,
            fileName: "command-prompt",
            includeResolver: { path in
                try String(contentsOf: URL(filePath: path), encoding: .utf8)
            },
            baseDirectory: TatamiConfigLoader.defaultFileURL.deletingLastPathComponent().path(percentEncoded: false)
        )
        config = updated
        return errors
    }

    /// 設定ファイルを読み直す。ファイルが無い・読めない (ディレクトリ・権限不足) 時は現在の設定を維持し、エラーだけを返す。
    /// 既定ファイルが無い時の再読込も現在の設定のままにする (既定値へ戻したい時はファイルを空にする)
    @discardableResult
    func reload(fileURL: URL, requireFile: Bool) -> [TatamiConfigError] {
        let loaded = TatamiConfigLoader.load(fileURL: fileURL, requireFile: requireFile)
        if loaded.parsed {
            config = loaded.config
        }
        loadErrors = loaded.errors
        return loaded.errors
    }
}
