import Foundation
import Observation

/// アプリ全体で 1 つの履歴・ブックマーク。複数の macOS ウィンドウが別々のコピーを持って互いの保存で上書きしないよう、ここに集約する。
/// 保存は変更のたびに debounce し、終了・ウィンドウを閉じる時は saveNow() で即時に書く
@MainActor
@Observable
final class BrowsingDataStore {
    static let shared = BrowsingDataStore()

    private(set) var data = BrowsingStore.loadOrEmpty()
    /// 保存の失敗を表示するための直近のエラー
    private(set) var lastSaveError: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// セッションの保存と同じ間隔 (BrowserWindowModel.saveDelay と同じ根拠)
    private static let saveDelay: Duration = .milliseconds(500)

    private init() {}

    /// 実際のナビゲーションによる訪問。履歴の先頭へ移し、訪問日時を更新する
    func recordVisit(url: URL, title: String) {
        data.recordVisit(url: url, title: title, date: Date())
        scheduleSave()
    }

    /// タイトルだけの更新 (未読件数を document.title に出すページ等)。順序と訪問日時は変えない
    func updateTitle(url: URL, title: String) {
        guard data.updateTitle(url: url, title: title) else {
            return
        }
        scheduleSave()
    }

    func addBookmark(url: URL, title: String) {
        data.addBookmark(url: url, title: title, date: Date())
        scheduleSave()
    }

    func removeBookmark(url: URL) {
        data.removeBookmark(url: url)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: BrowsingDataStore.saveDelay)
            guard !Task.isCancelled, let self else {
                return
            }
            saveNow()
        }
    }

    /// debounce を待たずに保存する (ウィンドウを閉じる時・終了時)
    func saveNow() {
        saveTask?.cancel()
        do {
            try BrowsingStore.save(data: data)
            lastSaveError = nil
        } catch {
            lastSaveError = "履歴の保存に失敗: \(error)"
        }
    }
}
