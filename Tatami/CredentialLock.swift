import Foundation
import LocalAuthentication
import Observation

/// 資格情報ストアのロック状態の純粋ロジック。最後に操作してから lockTimeout 秒を超えて使わなければロックされる
struct CredentialLockPolicy: Equatable {
    /// 自動ロックまでの秒数 (`set -g lock-timeout`)。0 は操作のたびに本人確認を求める
    var lockTimeout: TimeInterval = CredentialLockPolicy.defaultLockTimeout
    /// 最後に資格情報を操作した時刻。nil はロック中
    var lastUsedAt: Date?

    /// 既定の自動ロック時間。ログインフォームを開いてから送信までの一連の操作 (候補の選択・2 段階目の入力) を
    /// 再確認なしで済ませられ、かつ席を離れてから戻るまでの時間よりは短い値として 5 分を選んだ。
    /// 1Password の既定 (10 分) より短めにしているのは、macOS の画面ロックの既定 (スリープ後 5 分) と揃えるため
    static let defaultLockTimeout: TimeInterval = 300
    /// lock-timeout に設定できる範囲。上限は 1 日 (それ以上は実質「ロックしない」と同じで、設定の意図が読めなくなる)
    static let minimumLockTimeout = 0
    static let maximumLockTimeout = 86_400

    /// now 時点でロックされているか
    func isLocked(now: Date) -> Bool {
        guard let lastUsedAt, lockTimeout > 0 else {
            return true
        }
        return now.timeIntervalSince(lastUsedAt) > lockTimeout
    }

    /// 本人確認が通った (または操作した) 時刻を記録し、そこから lockTimeout の間アンロックされた状態にする
    mutating func touch(now: Date) {
        lastUsedAt = now
    }

    /// 即座にロックする
    mutating func lock() {
        lastUsedAt = nil
    }
}

/// 本人確認に失敗した・できなかったこと
struct CredentialLockError: Error, CustomStringConvertible {
    /// 表示用の説明。LocalAuthentication のエラーはコードだけだと原因が分からないため、説明文へ変換して持つ
    let description: String
}

/// 資格情報のロック / アンロックの状態。UI (status line の表示) と資格情報を扱う処理が同じ状態を参照するよう 1 か所で持つ。
/// アンロックは Touch ID、使えない環境 (Touch ID の無い Mac・GitHub Actions runner 等) ではログインパスワードにフォールバックする
/// (`deviceOwnerAuthentication` は生体認証が無ければパスワードに切り替わる)
@Observable
final class CredentialLock {
    /// アプリ全体で 1 つのロック状態
    static let shared = CredentialLock()

    /// 現在の状態。UI の表示は isLocked を通して参照する
    private(set) var policy = CredentialLockPolicy()
    /// 本人確認の実体。ユニットテストからは成功・失敗を固定した関数に差し替える
    @ObservationIgnored private let authenticate: (_ reason: String) async throws -> Void
    /// 自動ロックの時刻に isLocked の表示を更新するためのタスク
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// authenticate の既定は LocalAuthentication。テストからは差し替える
    init(authenticate: ((_ reason: String) async throws -> Void)? = nil) {
        self.authenticate = authenticate ?? CredentialLock.authenticateWithLocalAuthentication
    }

    /// 現在ロックされているか
    var isLocked: Bool {
        policy.isLocked(now: Date())
    }

    /// 自動ロックまでの時間を設定から反映する。短くなった場合はその時点で期限切れになることがある
    func apply(lockTimeout: TimeInterval) {
        policy.lockTimeout = lockTimeout
        scheduleExpiry()
    }

    /// 即座にロックする (`:lock` コマンド)
    func lock() {
        policy.lock()
        expiryTask?.cancel()
    }

    /// アンロック済みなら期限を延ばし、ロック中なら本人確認を行ってからアンロックする。失敗・キャンセルは throw する
    func ensureUnlocked(reason: String) async throws {
        if policy.isLocked(now: Date()) {
            try await authenticate(reason)
        }
        policy.touch(now: Date())
        scheduleExpiry()
    }

    /// 期限が来た時に policy を更新して表示を変える。lockTimeout 0 は操作直後にロックされるため即時
    private func scheduleExpiry() {
        expiryTask?.cancel()
        let timeout = policy.lockTimeout
        expiryTask = Task { [weak self] in
            // 期限ちょうどでは isLocked が false (境界は「超えたら」) のため 1 秒待ってから確認する
            try? await Task.sleep(for: .seconds(timeout + 1))
            guard let self, !Task.isCancelled, self.policy.isLocked(now: Date()) else {
                return
            }
            self.policy.lock()
        }
    }

    /// LocalAuthentication による本人確認。Touch ID が無い・登録されていない環境ではシステムがパスワード入力へ切り替える
    private static func authenticateWithLocalAuthentication(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw CredentialLockError(description: "本人確認を使えない: \(error?.localizedDescription ?? "不明")")
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw CredentialLockError(description: "本人確認に失敗")
            }
        } catch let laError as LAError {
            throw CredentialLockError(description: "本人確認に失敗: \(laError.localizedDescription)")
        }
    }
}
