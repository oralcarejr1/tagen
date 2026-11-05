import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import TagenCore

public struct ProcessLaunch: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var stdinText: String?      // written then stdin is closed (if keepStdinOpen == false)
    public var keepStdinOpen: Bool
    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String,
                stdinText: String? = nil, keepStdinOpen: Bool = false) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.workingDirectory = workingDirectory; self.stdinText = stdinText; self.keepStdinOpen = keepStdinOpen
    }
}

public enum ProcessOutput: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exited(Int32)
}

/// Runs a subprocess and streams its stdout/stderr line by line. Thread-safe.
public final class JSONLProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stdinClosed = false
    private var stderrTail: [String] = []
    private var continuation: AsyncStream<ProcessOutput>.Continuation?
    public let output: AsyncStream<ProcessOutput>
    private var terminated = false
    private let eofGroup = DispatchGroup()

    public init() {
        var c: AsyncStream<ProcessOutput>.Continuation!
        output = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }
    public var recentStderr: [String] { lock.lock(); defer { lock.unlock() }; return stderrTail }

    public func launch(_ spec: ProcessLaunch) throws {
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = URL(fileURLWithPath: spec.workingDirectory)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        eofGroup.enter(); eofGroup.enter()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; self.flush(stdout: true); self.eofGroup.leave(); return }
            self.append(d, stdout: true)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; self.flush(stdout: false); self.eofGroup.leave(); return }
            self.append(d, stdout: false)
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            let status = p.terminationStatus
            // Wait for pipes to drain so no output line is lost after exit.
            DispatchQueue.global().async {
                _ = self.eofGroup.wait(timeout: .now() + 2)
                self.continuation?.yield(.exited(status))
                self.continuation?.finish()
            }
        }
        try process.run()
        if let t = spec.stdinText { writeRaw(Data(t.utf8)) }
        if !spec.keepStdinOpen { closeStdin() }
    }

    public func writeLine(_ line: String) {
        writeRaw(Data((line + "\n").utf8))
    }

    private func writeRaw(_ data: Data) {
        lock.lock(); let closed = stdinClosed; lock.unlock()
        guard !closed, process.isRunning else { return }
        do { try stdinPipe.fileHandleForWriting.write(contentsOf: data) } catch { }
    }

    public func closeStdin() {
        lock.lock(); defer { lock.unlock() }
        guard !stdinClosed else { return }
        stdinClosed = true
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// SIGINT → SIGTERM → SIGKILL with grace periods.
    public func terminate(grace: Double = 2.0) {
        lock.lock(); if terminated { lock.unlock(); return }; terminated = true; lock.unlock()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace / 2) { [process] in
            if process.isRunning { kill(pid, SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + grace / 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private func append(_ d: Data, stdout: Bool) {
        lock.lock()
        if stdout { stdoutBuffer.append(d) } else { stderrBuffer.append(d) }
        var lines: [String] = []
        while true {
            let buf = stdout ? stdoutBuffer : stderrBuffer
            guard let nl = buf.firstIndex(of: 0x0A) else { break }
            let lineData = buf[buf.startIndex..<nl]
            let rest = buf[buf.index(after: nl)...]
            if stdout { stdoutBuffer = Data(rest) } else { stderrBuffer = Data(rest) }
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
        }
        if !stdout {
            stderrTail.append(contentsOf: lines)
            if stderrTail.count > 50 { stderrTail.removeFirst(stderrTail.count - 50) }
        }
        lock.unlock()
        for l in lines where !l.isEmpty { continuation?.yield(stdout ? .stdout(l) : .stderr(l)) }
    }

    private func flush(stdout: Bool) {
        lock.lock()
        let buf = stdout ? stdoutBuffer : stderrBuffer
        if stdout { stdoutBuffer = Data() } else { stderrBuffer = Data() }
        let line = String(decoding: buf, as: UTF8.self).trimmingCharacters(in: .newlines)
        if !stdout && !line.isEmpty { stderrTail.append(line) }
        lock.unlock()
        if !line.isEmpty { continuation?.yield(stdout ? .stdout(line) : .stderr(line)) }
    }
}
