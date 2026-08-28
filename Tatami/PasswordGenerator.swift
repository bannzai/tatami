import Foundation

/// 強いパスワードの生成規則 (純粋ロジック)。規則は tatami.conf の `set -g password-length` / `set -g password-symbols` で変えられる
struct PasswordGenerator: Equatable {
    /// 生成する長さ。多くのサイトの上限 (20〜64 文字) に収まり、英数記号 20 文字で約 130 bit の強度になるため 20 を既定にした
    var length = 20
    /// 記号を含めるか。記号を許さないサイトのために切れるようにする。既定は含める
    var includesSymbols = true

    static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let digits = Array("0123456789")
    /// 記号はシェルや URL で問題になりにくく、多くのサイトが許すものだけにする
    static let symbols = Array("!#$%&*+-=?@^_")
    /// 最小の長さ。各文字種を最低 1 文字含める規則を満たせる最小値 (英小・英大・数字・記号)
    static let minimumLength = 8
    /// 最大の長さ。多くのサイトの上限 (64〜128) を超える値は入力ミスとみなし、巨大な値でメインスレッドを止めない
    static let maximumLength = 128

    /// 各文字種を最低 1 文字含み、残りは全文字種から一様に選ぶ。位置は最後にシャッフルする
    func generate<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        let classes = [PasswordGenerator.lowercase, PasswordGenerator.uppercase, PasswordGenerator.digits] + (includesSymbols ? [PasswordGenerator.symbols] : [])
        let all = classes.flatMap { $0 }
        var characters = classes.map { $0.randomElement(using: &generator)! }
        while characters.count < min(max(length, PasswordGenerator.minimumLength), PasswordGenerator.maximumLength) {
            characters.append(all.randomElement(using: &generator)!)
        }
        characters.shuffle(using: &generator)
        return String(characters)
    }

    func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }
}
