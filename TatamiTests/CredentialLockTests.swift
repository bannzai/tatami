import Foundation
import Testing
@testable import Tatami

struct CredentialLockTests {
    @Test func locksAfterTimeoutSinceLastUse() {
        var policy = CredentialLockPolicy(lockTimeout: 60)
        let start = ContinuousClock.now
        #expect(policy.isLocked(now: start))
        policy.touch(now: start)
        #expect(!policy.isLocked(now: start.advanced(by: .seconds(59))))
        #expect(policy.isLocked(now: start.advanced(by: .seconds(60))))
        policy.touch(now: start.advanced(by: .seconds(50)))
        #expect(!policy.isLocked(now: start.advanced(by: .seconds(100))))
        policy.lock()
        #expect(policy.isLocked(now: start.advanced(by: .seconds(50))))
    }

    @Test func zeroTimeoutLocksImmediately() {
        var policy = CredentialLockPolicy(lockTimeout: 0)
        let now = ContinuousClock.now
        policy.touch(now: now)
        #expect(policy.isLocked(now: now))
    }

    @Test func authenticatesOnlyWhileLocked() async throws {
        var authenticated = 0
        let lock = CredentialLock { _ in
            authenticated += 1
        }
        lock.apply(lockTimeout: 60)
        #expect(lock.isLocked)
        try await lock.ensureUnlocked(reason: "test")
        #expect(!lock.isLocked)
        try await lock.ensureUnlocked(reason: "test")
        #expect(authenticated == 1)
        lock.lock()
        #expect(lock.isLocked)
        try await lock.ensureUnlocked(reason: "test")
        #expect(authenticated == 2)
    }

    @Test func concurrentRequestsShareOneAuthentication() async throws {
        var authenticated = 0
        let lock = CredentialLock { _ in
            authenticated += 1
            try await Task.sleep(for: .milliseconds(50))
        }
        lock.apply(lockTimeout: 60)
        let first = Task {
            try await lock.ensureUnlocked(reason: "a")
        }
        let second = Task {
            try await lock.ensureUnlocked(reason: "b")
        }
        try await first.value
        try await second.value
        #expect(authenticated == 1)
        #expect(!lock.isLocked)
    }

    @Test func lockDuringAuthenticationInvalidatesPendingRequest() async {
        // 本人確認が実際に始まったことを待ってから lock() する (固定待機による競合を避ける)
        let started = AsyncStream<Void>.makeStream()
        let lock = CredentialLock { _ in
            started.continuation.yield(())
            try await Task.sleep(for: .seconds(1))
        }
        lock.apply(lockTimeout: 60)
        let pending = Task {
            try await lock.ensureUnlocked(reason: "test")
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        lock.lock()
        let outcome = await pending.result
        #expect(throws: CredentialLockError.self) {
            try outcome.get()
        }
        #expect(lock.isLocked)
    }

    @Test func staysLockedWhenAuthenticationFails() async {
        let lock = CredentialLock { _ in
            throw CredentialLockError(description: "denied")
        }
        await #expect(throws: CredentialLockError.self) {
            try await lock.ensureUnlocked(reason: "test")
        }
        #expect(lock.isLocked)
    }

    @Test func lockTimeoutSetting() {
        var config = TatamiConfig()
        let errors = TatamiConfigParser.apply(text: "set -g lock-timeout 600\nset -g lock-timeout -1\nset -g lock-timeout abc\nset -g lock-timeout 0", config: &config)
        #expect(config.lockTimeout == 0)
        #expect(errors.map(\.line) == [2, 3])
    }
}
