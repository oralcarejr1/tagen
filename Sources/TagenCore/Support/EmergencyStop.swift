import Foundation

/// Global emergency stop. Triggering it synchronously notifies every registered handler
/// (cancel model requests, stop speech, kill agent processes, abort GUI automation,
/// clear overlays) and latches `isTriggered` until `reset()`.
///
/// It is deliberately lock-based and synchronous so it can be called from a hotkey
/// callback or signal handler without awaiting any actor.
public final class EmergencyStop: @unchecked Sendable {
    public static let shared = EmergencyStop()

    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (String) -> Void] = [:]
    private var triggered = false
    private var generation = 0
    private var lastReason: String?

    public init() {}

    @discardableResult
    public func register(_ handler: @escaping @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); handlers[id] = handler; lock.unlock()
        return id
    }

    public func unregister(_ id: UUID) {
        lock.lock(); handlers[id] = nil; lock.unlock()
    }

    public func trigger(reason: String = "user") {
        lock.lock()
        triggered = true
        generation += 1
        lastReason = reason
        let hs = Array(handlers.values)
        lock.unlock()
        for h in hs { h(reason) }
    }

    public func reset() {
        lock.lock(); triggered = false; lock.unlock()
    }

    public var isTriggered: Bool { lock.lock(); defer { lock.unlock() }; return triggered }
    public var currentGeneration: Int { lock.lock(); defer { lock.unlock() }; return generation }
    public var reason: String? { lock.lock(); defer { lock.unlock() }; return lastReason }

    /// Throws `EmergencyStopError` if a stop was triggered after `sinceGeneration`.
    public func check(sinceGeneration: Int) throws {
        lock.lock(); let g = generation; let r = lastReason; lock.unlock()
        if g != sinceGeneration { throw EmergencyStopError(reason: r ?? "user") }
    }
}

public struct EmergencyStopError: Error, Sendable, Equatable, CustomStringConvertible {
    public let reason: String
    public var description: String { "Emergency stop: \(reason)" }
}
