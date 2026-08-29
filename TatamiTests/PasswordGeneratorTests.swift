import Testing
@testable import Tatami

/// 生成規則 (長さ・文字種・最小長) を検証する
struct PasswordGeneratorTests {
    /// 再現できる乱数
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    @Test func generatedPasswordContainsEveryClassAndHasRequestedLength() {
        var generator = SeededGenerator(state: 42)
        for _ in 0..<20 {
            let password = PasswordGenerator(length: 20, includesSymbols: true).generate(using: &generator)
            #expect(password.count == 20)
            #expect(password.contains { PasswordGenerator.lowercase.contains($0) })
            #expect(password.contains { PasswordGenerator.uppercase.contains($0) })
            #expect(password.contains { PasswordGenerator.digits.contains($0) })
            #expect(password.contains { PasswordGenerator.symbols.contains($0) })
        }
    }

    @Test func symbolsCanBeExcluded() {
        var generator = SeededGenerator(state: 7)
        let password = PasswordGenerator(length: 32, includesSymbols: false).generate(using: &generator)
        #expect(password.count == 32)
        #expect(!password.contains { PasswordGenerator.symbols.contains($0) })
    }

    @Test func lengthBelowMinimumIsRaised() {
        var generator = SeededGenerator(state: 1)
        #expect(PasswordGenerator(length: 3, includesSymbols: true).generate(using: &generator).count == PasswordGenerator.minimumLength)
    }

    @Test func systemGeneratorProducesDifferentPasswords() {
        let generator = PasswordGenerator()
        #expect(generator.generate() != generator.generate())
    }

    @Test func respectsMaxLength() {
        let generator = PasswordGenerator(length: 20, includesSymbols: true)
        #expect(generator.generate(maxLength: 12).count == 12)
        #expect(generator.generate(maxLength: 0).count == 20)
        #expect(generator.generate(maxLength: 100).count == 20)
        // 上限が設定長より短くても各文字種を含む (上限が文字種数以上の場合)
        let short = generator.generate(maxLength: 8)
        #expect(short.count == 8)
        #expect(short.contains(where: \.isLowercase) && short.contains(where: \.isUppercase) && short.contains(where: \.isNumber))
    }
}
