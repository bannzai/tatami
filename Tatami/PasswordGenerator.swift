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
    /// 生成する実際の長さ。maxLength (対象欄の上限。0/nil は上限なし) があればそこまで縮め、各文字種を 1 文字ずつ含められる下限 (classCount)
    /// は下回らない。上限が classCount 未満のサイトは各文字種を保証できないため、その最小値まで
    func effectiveLength(maxLength: Int?) -> Int {
        let classCount = includesSymbols ? 4 : 3
        let upperBound = maxLength.flatMap { $0 > 0 ? min($0, PasswordGenerator.maximumLength) : nil } ?? PasswordGenerator.maximumLength
        let base = min(max(length, PasswordGenerator.minimumLength), PasswordGenerator.maximumLength)
        return max(min(base, upperBound), min(classCount, upperBound))
    }

    /// 各文字種を最低 1 文字含み (欄の上限がそれも許さない時を除く)、残りは全文字種から一様に選ぶ。位置は最後にシャッフルする
    func generate<Generator: RandomNumberGenerator>(maxLength: Int? = nil, using generator: inout Generator) -> String {
        let classes = [PasswordGenerator.lowercase, PasswordGenerator.uppercase, PasswordGenerator.digits] + (includesSymbols ? [PasswordGenerator.symbols] : [])
        let all = classes.flatMap { $0 }
        let target = effectiveLength(maxLength: maxLength)
        // 上限が文字種数より短い時は先頭から必要数だけ (各文字種の保証は諦める)
        var characters = Array(classes.map { $0.randomElement(using: &generator)! }.prefix(target))
        while characters.count < target {
            characters.append(all.randomElement(using: &generator)!)
        }
        characters.shuffle(using: &generator)
        return String(characters)
    }

    func generate(maxLength: Int? = nil) -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(maxLength: maxLength, using: &generator)
    }
}
