import Foundation

/// 表示中のページに対して、どの資格情報を候補にするかの規則 (純粋ロジック)。
/// 同じオリジン (scheme + host + port) を優先し、Public Suffix List で求めた同じ登録可能ドメイン (eTLD+1) のサブドメイン違いも候補に含める
/// (`accounts.example.com` で保存したものを `example.com` でも出す)。HTTPS の資格情報を HTTP のページには出さない (平文の通信へ渡さない)
enum CredentialMatcher {
    /// 登録可能ドメイン (eTLD+1)。IP アドレス・1 ラベルのホスト・リストに無い TLD は nil (完全一致だけにする)
    static func registrableDomain(host: String, rules: PublicSuffixList.Rules = PublicSuffixList.bundled) -> String? {
        let lowered = host.lowercased()
        guard lowered.contains("."), !isIPAddress(host: lowered) else {
            return nil
        }
        return rules.registrableDomain(host: lowered)
    }

    /// 資格情報の URL と充填先フレームの URL が同じオリジン (scheme・host・port の完全一致) か。
    /// iframe への充填はこの条件に限る (同じ eTLD+1 の別サブドメインの iframe に資格情報を渡さない)
    static func sameOrigin(credentialURL: URL, pageURL: URL) -> Bool {
        guard let credentialHost = host(url: credentialURL), let pageHost = host(url: pageURL), !credentialHost.isEmpty else {
            return false
        }
        return credentialHost == pageHost
            && credentialURL.scheme?.lowercased() == pageURL.scheme?.lowercased()
            && port(url: credentialURL) == port(url: pageURL)
    }

    /// 資格情報の URL がページの URL に対して候補になるか
    static func matches(credentialURL: URL, pageURL: URL, rules: PublicSuffixList.Rules = PublicSuffixList.bundled) -> Bool {
        guard let credentialHost = host(url: credentialURL), let pageHost = host(url: pageURL),
              !credentialHost.isEmpty, !pageHost.isEmpty else {
            return false
        }
        let credentialScheme = credentialURL.scheme?.lowercased() ?? ""
        let pageScheme = pageURL.scheme?.lowercased() ?? ""
        // https で保存したものを http (やその他のスキーム) のページへ降格して出さない。http で保存したものを https で使うのは許す
        guard pageScheme == credentialScheme || (credentialScheme == "http" && pageScheme == "https") else {
            return false
        }
        guard port(url: credentialURL) == port(url: pageURL) else {
            return false
        }
        if credentialHost == pageHost {
            return true
        }
        guard let credentialDomain = registrableDomain(host: credentialHost, rules: rules),
              let pageDomain = registrableDomain(host: pageHost, rules: rules) else {
            return false
        }
        return credentialDomain == pageDomain
    }

    /// ページに対する候補。同じオリジン (scheme・host・port の一致) → 同じホストの http からの昇格 → 同じ登録可能ドメインの順で、
    /// それぞれ更新日時の新しい順 (既定の選択で別スキーム用のパスワードを入れない)
    static func candidates(credentials: [Credential], pageURL: URL, rules: PublicSuffixList.Rules = PublicSuffixList.bundled) -> [Credential] {
        let matching = credentials.filter { matches(credentialURL: $0.url, pageURL: pageURL, rules: rules) }.sorted { $0.updatedAt > $1.updatedAt }
        let pageHost = host(url: pageURL) ?? ""
        let exact = matching.filter { sameOrigin(credentialURL: $0.url, pageURL: pageURL) }
        let upgraded = matching.filter { !sameOrigin(credentialURL: $0.url, pageURL: pageURL) && host(url: $0.url) == pageHost }
        let related = matching.filter { host(url: $0.url) != pageHost }
        return exact + upgraded + related
    }

    /// 照合に使うホスト。IDN は Unicode 表記 (`URL.host()` は percent-encoded で返す) と punycode (`xn--`) で表現が分かれるため、
    /// 常に IDNA の ASCII 形 (`encodedHost`) に揃える
    static func host(url: URL) -> String? {
        // IP アドレスは表記 (`[::1]` と `[0:0:0:0:0:0:0:1]` 等) を標準形に揃える (PasswordImporter.matchKey と同じ)。
        // 完全修飾名の末尾ドット (`example.com.`) は同じ DNS ホストなので取り除いてから比べる
        ((URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost ?? url.host())?.lowercased()).map { raw in
            PasswordImporter.normalizedHost(host: raw.count > 1 && raw.hasSuffix(".") ? String(raw.dropLast()) : raw)
        }
    }

    /// 既定ポートの明示 (https の 443 等) は省略と同一視する
    private static func port(url: URL) -> Int? {
        let scheme = url.scheme?.lowercased() ?? ""
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        return url.port.flatMap { $0 == defaultPort ? nil : $0 }
    }

    private static func isIPAddress(host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
