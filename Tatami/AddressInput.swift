import Foundation

/// アドレスバーの入力を URL に解決する純粋ロジック (ユニットテスト対象)
enum AddressInput {
    /// 起動直後に表示する空ページ。ホームページは tatami.conf で設定できるようにする予定で、それまでは about:blank にする
    static let homeURL = URL(string: "about:blank")!
    /// 検索エンジンの既定。作者が普段使っている Google を選んだ。tatami.conf で変更できるようにする予定
    static let defaultSearchURL = URL(string: "https://www.google.com/search")!

    /// スキーム付きならそのまま URL にし、空白を含まずドットを含む語は https を補ってホストとして扱い、
    /// それ以外は searchURL の q パラメータに入れた検索 URL にする
    static func resolve(text: String, searchURL: URL = defaultSearchURL) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil || url.scheme == "about" {
            return url
        }
        if !trimmed.contains(" "), trimmed.contains("."), let url = URL(string: "https://\(trimmed)"), url.host != nil {
            return url
        }
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url!
    }
}
