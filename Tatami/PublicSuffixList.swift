import Foundation

/// Public Suffix List (https://publicsuffix.org/) による登録可能ドメイン (eTLD+1) の判定。
/// `github.io` のように各サブドメインが別のユーザーに属する公開サフィックスを固定の列挙で近似すると、別テナントのページに資格情報を出してしまうため、
/// リスト全体をアプリに同梱する (Tatami/PublicSuffixList.dat。更新は同ファイルの差し替え)
enum PublicSuffixList {
    /// 通常の規則 (`co.jp` 等)、ワイルドカード (`*.ck` の `ck`)、例外 (`!www.ck` の `www.ck`)
    struct Rules: Equatable {
        let rules: Set<String>
        let wildcards: Set<String>
        let exceptions: Set<String>

        /// リストの文法どおりに解釈する。`//` のコメント行と空行を無視し、PRIVATE セクション (github.io 等) も含める
        init(text: String) {
            var rules: Set<String> = []
            var wildcards: Set<String> = []
            var exceptions: Set<String> = []
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else {
                    continue
                }
                let rule = trimmed.split(separator: " ")[0].lowercased()
                if rule.hasPrefix("!") {
                    exceptions.insert(String(rule.dropFirst()))
                } else if rule.hasPrefix("*.") {
                    wildcards.insert(String(rule.dropFirst(2)))
                } else {
                    rules.insert(rule)
                }
            }
            self.rules = rules
            self.wildcards = wildcards
            self.exceptions = exceptions
        }

        /// 公開サフィックスの長さ (ラベル数)。リストに無い TLD は nil (安全側に倒し、呼び出し側は完全一致だけにする)
        func publicSuffixLabelCount(labels: [String]) -> Int? {
            var best: Int?
            for start in labels.indices {
                let candidate = labels[start...].joined(separator: ".")
                if exceptions.contains(candidate) {
                    // 例外規則はそのサフィックス自体が登録可能ドメインになる (公開サフィックスは 1 ラベル短い)
                    return labels.count - start - 1
                }
                if rules.contains(candidate) {
                    best = max(best ?? 0, labels.count - start)
                }
                if start > 0, wildcards.contains(candidate) {
                    best = max(best ?? 0, labels.count - start + 1)
                }
            }
            return best
        }

        /// 登録可能ドメイン (eTLD+1)。公開サフィックスそのもの・リストに無い TLD・ラベルが足りない場合は nil
        func registrableDomain(host: String) -> String? {
            let labels = host.lowercased().split(separator: ".").map(String.init)
            guard let suffixCount = publicSuffixLabelCount(labels: labels), labels.count > suffixCount else {
                return nil
            }
            return labels.suffix(suffixCount + 1).joined(separator: ".")
        }
    }

    /// 同梱したリスト。読めない時は空の規則 (全て「リストに無い」扱いで完全一致だけになる)
    static let bundled: Rules = {
        guard let url = Bundle.main.url(forResource: "PublicSuffixList", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Rules(text: "")
        }
        return Rules(text: text)
    }()
}
