import Foundation

public enum LogLevel: Int, Sendable, Comparable, Codable {
    case debug = 0, info, warning, error
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

public protocol LogSink: Sendable {
    func write(level: LogLevel, category: String, message: String)
}

/// Writes to stderr. On macOS the app installs an os.Logger-backed sink instead.
public struct StderrLogSink: LogSink {
    public init() {}
    public func write(level: LogLevel, category: String, message: String) {
        let line = "[\(level)] [\(category)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// Captures log lines in memory (tests, diagnostics panel).
public final class MemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    public init() {}
    public func write(level: LogLevel, category: String, message: String) {
        lock.lock(); _lines.append("[\(level)] [\(category)] \(message)"); lock.unlock()
    }
    public var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}

/// Logger that always redacts secrets before writing.
public struct Log: Sendable {
    public let category: String
    private let sink: LogSink
    private let redactor: Redactor
    private let minLevel: LogLevel

    public init(_ category: String, sink: LogSink = LogConfig.shared.sink, minLevel: LogLevel = LogConfig.shared.minLevel) {
        self.category = category
        self.sink = sink
        self.redactor = Redactor()
        self.minLevel = minLevel
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        guard level >= minLevel else { return }
        sink.write(level: level, category: category, message: redactor.redact(message()))
    }
    public func debug(_ m: @autoclosure () -> String) { log(.debug, m()) }
    public func info(_ m: @autoclosure () -> String) { log(.info, m()) }
    public func warning(_ m: @autoclosure () -> String) { log(.warning, m()) }
    public func error(_ m: @autoclosure () -> String) { log(.error, m()) }
}

public final class LogConfig: @unchecked Sendable {
    public static let shared = LogConfig()
    private let lock = NSLock()
    private var _sink: LogSink = StderrLogSink()
    private var _min: LogLevel = .info
    public var sink: LogSink {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }
    public var minLevel: LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return _min }
        set { lock.lock(); _min = newValue; lock.unlock() }
    }
}
