import AppKit
import WebKit

/// アプリ全体のダウンロードを保持する。WKDownload は delegate を弱参照するため、ダウンロード元のペインを閉じても完了・失敗まで受け取れるよう
/// ペインより長寿命なここが delegate になる。保存先は ~/Downloads で、進行中のダウンロードの保存先も含めて同名を避ける
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    /// 進捗・完了・失敗の通知先 (status line)。表示中のウィンドウが登録する
    var onMessage: ((String) -> Void)?

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

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destinationURL = uniqueFileURL(directoryURL: directoryURL, fileName: suggestedFilename)
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
                self.onMessage?("ダウンロード中 \(percent)%: \(destinationURL.lastPathComponent)")
            }
        }
        entries[download] = entry
        onMessage?("ダウンロード開始: \(destinationURL.lastPathComponent)")
        return destinationURL
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let entry = entries.removeValue(forKey: download) {
            onMessage?("ダウンロード完了: \(entry.destinationURL.path(percentEncoded: false))")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let name = entries.removeValue(forKey: download)?.destinationURL.lastPathComponent ?? ""
        onMessage?("ダウンロード失敗: \(name) \(error.localizedDescription)")
    }

    /// 既存のファイルと、進行中のダウンロードが予約した保存先を避けて `name (2).ext` のように連番を付ける
    /// (同名を同時に落とすと、最初のファイルが作られる前に両方が同じ名前を選んでしまうため)
    private func uniqueFileURL(directoryURL: URL, fileName: String) -> URL {
        let reserved = Set(entries.values.map(\.destinationURL))
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directoryURL.appending(path: fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) || reserved.contains(candidate) {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directoryURL.appending(path: numbered)
            counter += 1
        }
        return candidate
    }
}
