import Foundation

/// アドレスバーの入力を URL に解決する純粋ロジック (ユニットテスト対象)
enum AddressInput {
    /// 起動直後に表示する空ページ。ホームページは tatami.conf で設定できるようにする予定で、それまでは about:blank にする
    static let homeURL = URL(string: "about:blank")!
    /// 検索エンジンの既定。作者が普段使っている Google を選んだ。tatami.conf で変更できるようにする予定
    static let defaultSearchURL = URL(string: "https://www.google.com/search")!

    /// 入力の種類に応じて URL を決める。
    /// スキーム付きはそのまま、localhost・IP アドレス (ポート付き含む) は http を補い、
    /// 空白と @ を含まずドットを含む語は https を補ってホストとして扱い、それ以外 (メールアドレスを含む) は検索語にする
    static func resolve(text: String, searchURL: URL = defaultSearchURL) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil || url.scheme == "about" {
            return url
        }
        if isLocalHost(trimmed), let url = URL(string: "http://\(trimmed)"), url.host != nil {
            return url
        }
        if !trimmed.contains(" "), !trimmed.contains("@"), trimmed.contains("."),
           let url = URL(string: "https://\(trimmed)"), url.host != nil {
            return url
        }
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        // 設定の検索 URL に含まれるパラメータは残す。値が空文字のパラメータ (`?p=`) があればそこに検索語を入れ、無ければ `q` を足す。
        // 値そのものが無いパラメータ (`?flag`) は固定フラグとしてそのまま残す
        var queryItems = components.queryItems ?? []
        if let index = queryItems.firstIndex(where: { $0.value == "" }) {
            queryItems[index] = URLQueryItem(name: queryItems[index].name, value: trimmed)
        } else {
            queryItems.append(URLQueryItem(name: "q", value: trimmed))
        }
        components.queryItems = queryItems
        return components.url!
    }

    /// 開発中のローカルサーバー (localhost / IPv4 / IPv6 の [::1] 等、任意でポートとパス付き) かどうか。
    /// これらはドットが無い・数字だけといった理由で通常のホスト判定から漏れるため、個別に認識する
    private static func isLocalHost(_ text: String) -> Bool {
        let hostPart = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
        if hostPart.hasPrefix("[") {
            // IPv6 は [::1] / [::1]:3000 の形
            return hostPart.contains("]")
        }
        let host = hostPart.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
        if host == "localhost" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil }
    }
}
