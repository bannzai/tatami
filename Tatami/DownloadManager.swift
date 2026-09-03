import AppKit
import WebKit

/// アプリ全体のダウンロードを保持する。WKDownload は delegate を弱参照するため、ダウンロード元のペインを閉じても完了・失敗まで受け取れるよう
/// ペインより長寿命なここが delegate になる。保存先は NSSavePanel でユーザーが選ぶ (キャンセルでダウンロード中止)
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    /// 進捗・完了・失敗の通知先 (status line)。表示中の全ウィンドウに配る (どのウィンドウから始めたダウンロードでも見える)。
    /// 弱参照で持ち、閉じたウィンドウは自然に外れる
    private let subscribers = NSHashTable<BrowserWindowModel>.weakObjects()

    func subscribe(model: BrowserWindowModel) {
        subscribers.add(model)
    }

    func unsubscribe(model: BrowserWindowModel) {
        subscribers.remove(model)
    }

    private func onMessage(_ message: String) {
        for model in subscribers.allObjects {
            model.showDownloadMessage(message)
        }
    }

    /// 1 つのダウンロードの保存先と進捗の監視
    private final class Entry {
        let destinationURL: URL
        var observation: NSKeyValueObservation?
        init(destinationURL: URL) {
            self.destinationURL = destinationURL
        }
    }

    private var entries: [WKDownload: Entry] = [:]

    /// WebKit から渡されたダウンロードを引き受ける
    func adopt(download: WKDownload) {
        download.delegate = self
    }

    /// サーバー由来の suggestedFilename を 1 つのファイル名に制限する (`../` などのパス区切りで Downloads の外へ書かせない)
    static func sanitizedFileName(_ suggested: String) -> String {
        let name = (suggested as NSString).lastPathComponent
        // 空・カレント・親ディレクトリは保存名にならないため既定名にする
        if name.isEmpty || name == "." || name == ".." {
            return "download"
        }
        return name
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DownloadManager.sanitizedFileName(suggestedFilename)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        panel.canCreateDirectories = true
        let panelResponse: NSApplication.ModalResponse
        if let window = download.webView?.window {
            panelResponse = await panel.beginSheetModal(for: window)
        } else {
            panelResponse = panel.runModal()
        }
        guard panelResponse == .OK, let destinationURL = panel.url else {
            onMessage("ダウンロードを中止しました: \(DownloadManager.sanitizedFileName(suggestedFilename))")
            return nil
        }
        // NSSavePanel で置き換えを確認済みでも、WKDownload は既存ファイルがあると保存に失敗するため先に取り除く
        try? FileManager.default.removeItem(at: destinationURL)
        let entry = Entry(destinationURL: destinationURL)
        entry.observation = download.progress.observe(\.fractionCompleted) { [weak self, weak download] progress, _ in
            guard let self, let download else {
                return
            }
            let percent = Int(progress.fractionCompleted * 100)
            Task { @MainActor in
                // 完了・失敗の後に届く進捗 (100%) で完了のメッセージを上書きしない
                guard self.entries[download] != nil else {
                    return
                }
                self.onMessage("ダウンロード中 \(percent)%: \(destinationURL.lastPathComponent)")
            }
        }
        entries[download] = entry
        onMessage("ダウンロード開始: \(destinationURL.lastPathComponent)")
        return destinationURL
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let entry = entries.removeValue(forKey: download) {
            onMessage("ダウンロード完了: \(entry.destinationURL.path(percentEncoded: false))")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let name = entries.removeValue(forKey: download)?.destinationURL.lastPathComponent ?? ""
        onMessage("ダウンロード失敗: \(name) \(error.localizedDescription)")
    }
}
