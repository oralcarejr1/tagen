import Foundation

public struct TimeoutError: Error, Sendable, Equatable, CustomStringConvertible {
    public let seconds: Double
    public let operation: String
    public init(seconds: Double, operation: String) { self.seconds = seconds; self.operation = operation }
    public var description: String { "Timed out after \(seconds)s: \(operation)" }
}

/// Run `operation` with a deadline. The operation is cancelled when the deadline passes.
public func withTimeout<T: Sendable>(
    seconds: Double,
    operation name: String = "operation",
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw TimeoutError(seconds: seconds, operation: name)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

/// Simple lock-protected value box for cross-thread state that must be readable synchronously.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
    public var current: Value { withLock { $0 } }
    public func set(_ v: Value) { withLock { $0 = v } }
}

/// Abstract clock to make retry/backoff/polling logic deterministic in tests.
public protocol SleepClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemClock: SleepClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Test clock: sleeping advances virtual time instantly.
public final class VirtualClock: SleepClock, @unchecked Sendable {
    private let state: Locked<Date>
    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { state = Locked(start) }
    public func now() -> Date { state.current }
    public func advance(_ s: Double) { state.withLock { $0 = $0.addingTimeInterval(s) } }
    public func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        advance(seconds)
        await Task.yield()
    }
}

/// Exponential backoff policy with bounded attempts.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: Double
    public var maxDelay: Double
    public init(maxAttempts: Int = 3, baseDelay: Double = 0.5, maxDelay: Double = 8) {
        self.maxAttempts = maxAttempts; self.baseDelay = baseDelay; self.maxDelay = maxDelay
    }
    public func delay(forAttempt attempt: Int) -> Double {
        min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
    }
    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)
}
