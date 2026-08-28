import Foundation

/// 表示中のページのホストに対して、どの資格情報を候補にするかの規則 (純粋ロジック)。
/// 完全一致を優先し、同じ登録可能ドメイン (eTLD+1) のサブドメイン違いも候補に含める (`accounts.example.com` で保存したものを `example.com` でも出す)
enum CredentialMatcher {
    /// 2 段の公開サフィックス。ホストの末尾がこれに当たる時は末尾 3 ラベルを登録可能ドメインとする。
    /// 公開サフィックスリスト全体は持たず、作者が使う地域 (日本) と主要な国別ドメインだけを列挙する
    static let twoLevelPublicSuffixes: Set<String> = [
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ad.jp", "lg.jp", "gr.jp",
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.nz",
        "com.br", "com.cn", "com.tw", "co.kr", "com.sg", "co.in", "com.mx", "com.ar",
    ]

    /// 登録可能ドメイン (eTLD+1)。IP アドレスや 1 ラベルのホスト (localhost) はそのまま返す
    static func registrableDomain(host: String) -> String {
        let lowered = host.lowercased()
        let labels = lowered.split(separator: ".").map(String.init)
        guard labels.count >= 2, !isIPAddress(host: lowered) else {
            return lowered
        }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if twoLevelPublicSuffixes.contains(lastTwo), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// 資格情報のホストがページのホストに対して候補になるか
    static func matches(credentialHost: String, pageHost: String) -> Bool {
        let credential = credentialHost.lowercased()
        let page = pageHost.lowercased()
        guard !credential.isEmpty, !page.isEmpty else {
            return false
        }
        if credential == page {
            return true
        }
        // IP アドレスと 1 ラベルのホストは完全一致だけ
        guard !isIPAddress(host: page), page.contains("."), credential.contains(".") else {
            return false
        }
        return registrableDomain(host: credential) == registrableDomain(host: page)
    }

    /// ページのホストに対する候補。完全一致 → 同じ登録可能ドメインの順で、それぞれ更新日時の新しい順
    static func candidates(credentials: [Credential], pageHost: String) -> [Credential] {
        let matching = credentials.filter { matches(credentialHost: $0.host, pageHost: pageHost) }
        let page = pageHost.lowercased()
        let exact = matching.filter { $0.host == page }.sorted { $0.updatedAt > $1.updatedAt }
        let related = matching.filter { $0.host != page }.sorted { $0.updatedAt > $1.updatedAt }
        return exact + related
    }

    private static func isIPAddress(host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
