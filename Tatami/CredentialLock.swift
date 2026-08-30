import Foundation
import LocalAuthentication
import Observation

/// 資格情報ストアのロック状態の純粋ロジック。最後に操作してから lockTimeout 秒を超えて使わなければロックされる
struct CredentialLockPolicy: Equatable {
    /// 自動ロックまでの秒数 (`set -g lock-timeout`)。0 は操作のたびに本人確認を求める
    var lockTimeout: TimeInterval = CredentialLockPolicy.defaultLockTimeout
    /// 最後に資格情報を操作した時刻。nil はロック中。システム時計の変更 (過去への補正) でロックが遅れないよう単調時計で持つ
    var lastUsedAt: ContinuousClock.Instant?

    /// 既定の自動ロック時間。ログインフォームを開いてから送信までの一連の操作 (候補の選択・2 段階目の入力) を
    /// 再確認なしで済ませられ、かつ席を離れてから戻るまでの時間よりは短い値として 5 分を選んだ。
    /// 1Password の既定 (10 分) より短めにしているのは、macOS の画面ロックの既定 (スリープ後 5 分) と揃えるため
    static let defaultLockTimeout: TimeInterval = 300
    /// lock-timeout に設定できる範囲。上限は 1 日 (それ以上は実質「ロックしない」と同じで、設定の意図が読めなくなる)
    static let minimumLockTimeout = 0
    static let maximumLockTimeout = 86_400

    /// now 時点でロックされているか
    func isLocked(now: ContinuousClock.Instant) -> Bool {
        guard let lastUsedAt, lockTimeout > 0 else {
            return true
        }
        return now - lastUsedAt >= .seconds(lockTimeout)
    }

    /// 本人確認が通った (または操作した) 時刻を記録し、そこから lockTimeout の間アンロックされた状態にする
    mutating func touch(now: ContinuousClock.Instant) {
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
    /// ロック状態へ移った時 (`:lock`・自動ロック) の通知。表示中の候補一覧などロック前提の UI を閉じるために使う
    static let didLockNotification = Notification.Name("CredentialLock.didLock")

    /// 現在の状態。UI の表示は isLocked を通して参照する
    private(set) var policy = CredentialLockPolicy()
    /// 本人確認の実体。ユニットテストからは成功・失敗を固定した関数に差し替える
    @ObservationIgnored private let authenticate: (_ reason: String) async throws -> Void
    /// 自動ロックの時刻に isLocked の表示を更新するためのタスク
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// 進行中の本人確認。複数の要求で共有する
    @ObservationIgnored private var pendingAuthentication: Task<Void, any Error>?
    /// 明示的なロック (`:lock`) の回数。本人確認の待機中にロックされた要求を、確認が通っても無効にするために持つ
    @ObservationIgnored private var lockGeneration = 0

    /// authenticate の既定は LocalAuthentication。テストからは差し替える
    init(authenticate: ((_ reason: String) async throws -> Void)? = nil) {
        self.authenticate = authenticate ?? CredentialLock.authenticateWithLocalAuthentication
    }

    /// 現在ロックされているか
    var isLocked: Bool {
        policy.isLocked(now: .now)
    }

    /// 自動ロックまでの時間を設定から反映する。短くなった場合はその時点で期限切れになることがある
    func apply(lockTimeout: TimeInterval) {
        policy.lockTimeout = lockTimeout
        scheduleExpiry()
    }

    /// 即座にロックする (`:lock` コマンド)
    func lock() {
        policy.lock()
        lockGeneration += 1
        expiryTask?.cancel()
        // 待機中の本人確認はロック前の要求のものなので、以後の要求には使わない
        pendingAuthentication = nil
        NotificationCenter.default.post(name: CredentialLock.didLockNotification, object: self)
    }

    /// アンロックの状態に関わらず、この要求のために本人確認を行う (WebAuthn の UV のように「この操作で確認した」ことが要る時)。
    /// 成功したらアンロック状態も更新する
    func authenticateNow(reason: String) async throws {
        let generation = lockGeneration
        try await authenticate(reason)
        guard generation == lockGeneration else {
            throw CredentialLockError(description: "本人確認の間にロックされたため中断")
        }
        policy.touch(now: .now)
        scheduleExpiry()
    }

    /// アンロック済みなら期限を延ばし、ロック中なら本人確認を行ってからアンロックする。失敗・キャンセルは throw する。
    /// 待機中に `lock()` が実行された要求は、本人確認が通っても実行しない
    func ensureUnlocked(reason: String) async throws {
        let generation = lockGeneration
        if policy.isLocked(now: .now) {
            // 同時に複数の要求 (prefix + a の連打・別ウィンドウのエクスポート) が来ても本人確認は 1 回にまとめ、全員が同じ結果を待つ。
            // lock-timeout 0 (操作のたびに確認する設定) では共有せず、要求ごとに確認する
            let shared = policy.lockTimeout > 0
            let task = (shared ? pendingAuthentication : nil) ?? Task { [authenticate] in
                try await authenticate(reason)
            }
            if shared {
                pendingAuthentication = task
            }
            defer {
                if pendingAuthentication == task {
                    pendingAuthentication = nil
                }
            }
            try await task.value
        }
        guard generation == lockGeneration else {
            throw CredentialLockError(description: "本人確認の間にロックされたため中断")
        }
        policy.touch(now: .now)
        scheduleExpiry()
    }

    /// 期限が来た時に policy を更新して表示を変える。残り時間は最後の操作時刻から数える (別ウィンドウの作成などで
    /// apply が呼ばれても期限を延ばさない)。既に期限切れなら即座にロックの状態にする
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let lastUsedAt = policy.lastUsedAt else {
            return
        }
        let remaining = Duration.seconds(policy.lockTimeout) - (ContinuousClock.now - lastUsedAt)
        guard remaining > .zero else {
            policy.lock()
            NotificationCenter.default.post(name: CredentialLock.didLockNotification, object: self)
            return
        }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard let self, !Task.isCancelled, self.policy.isLocked(now: .now) else {
                return
            }
            self.policy.lock()
            NotificationCenter.default.post(name: CredentialLock.didLockNotification, object: self)
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
