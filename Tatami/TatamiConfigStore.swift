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

    /// 設定ファイルを読み直す。明示したファイルが無い時は現在の設定を維持し、エラーだけを返す
    @discardableResult
    func reload(fileURL: URL, requireFile: Bool) -> [TatamiConfigError] {
        let loaded = TatamiConfigLoader.load(fileURL: fileURL, requireFile: requireFile)
        if loaded.fileExists || !requireFile {
            config = loaded.config
        }
        loadErrors = loaded.errors
        return loaded.errors
    }
}
