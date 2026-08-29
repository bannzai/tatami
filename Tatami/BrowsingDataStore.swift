import Foundation
import Observation

/// アプリ全体で 1 つの履歴・ブックマーク。複数の macOS ウィンドウが別々のコピーを持って互いの保存で上書きしないよう、ここに集約する。
/// 保存は変更のたびに debounce し、終了・ウィンドウを閉じる時は saveNow() で即時に書く
@MainActor
@Observable
final class BrowsingDataStore {
    static let shared = BrowsingDataStore()

    private(set) var data: BrowsingData
    /// 保存の失敗を表示するための直近のエラー
    private(set) var lastSaveError: String?
    /// 読み込みに失敗して退避もできなかった時 false。元のファイルを空のデータで上書きしないよう保存しない
    private let isWritable: Bool
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// セッションの保存と同じ間隔 (BrowserWindowModel.saveDelay と同じ根拠)
    private static let saveDelay: Duration = .milliseconds(500)

    private init() {
        let loaded = BrowsingStore.loadOrEmpty()
        data = loaded.data
        isWritable = loaded.isWritable
        lastSaveError = loaded.problem
    }

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

    func addBookmark(url: URL, title: String, isTitleProvisional: Bool = false) {
        data.addBookmark(url: url, title: title, date: Date(), isTitleProvisional: isTitleProvisional)
        scheduleSave()
    }

    func removeBookmark(url: URL) {
        data.removeBookmark(url: url)
        scheduleSave()
    }

    /// 未保存の変更を最初に予約した時刻。連続する更新 (タイトルを更新し続けるページ等) で debounce が延び続けても maxSaveDelay で保存する
    @ObservationIgnored private var firstScheduledAt: ContinuousClock.Instant?
    /// セッションの保存と同じ根拠 (BrowserWindowModel.maxSaveDelay)
    private static let maxSaveDelay: Duration = .seconds(5)

    private func scheduleSave() {
        let now = ContinuousClock.now
        if let firstScheduledAt, now - firstScheduledAt >= BrowsingDataStore.maxSaveDelay {
            saveNow()
            return
        }
        if firstScheduledAt == nil {
            firstScheduledAt = now
        }
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
        firstScheduledAt = nil
        guard isWritable else {
            return
        }
        do {
            try BrowsingStore.save(data: data)
            lastSaveError = nil
        } catch {
            lastSaveError = "履歴の保存に失敗: \(error)"
        }
    }
}
