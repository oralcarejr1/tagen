import Foundation

/// Finds agent CLIs. GUI apps on macOS do not inherit the login shell's PATH, and npm-
/// installed CLIs need `node` on PATH, so we merge well-known locations with the PATH
/// reported by the user's login shell.
public struct ExecutableLocator: Sendable {
    public var overrides: [String: String]
    public var extraDirectories: [String]
    let fileExists: @Sendable (String) -> Bool

    public init(overrides: [String: String] = [:], extraDirectories: [String] = [],
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.overrides = overrides; self.extraDirectories = extraDirectories; self.fileExists = fileExists
    }

    public static func wellKnownDirectories(home: String = NSHomeDirectory()) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.claude/local",
         "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin", "\(home)/bin", "/usr/bin", "/bin"]
    }

    public func searchPath(loginShellPATH: String?, processPATH: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        var dirs: [String] = extraDirectories
        for p in [loginShellPATH, processPATH] { dirs += (p ?? "").split(separator: ":").map(String.init) }
        dirs += Self.wellKnownDirectories()
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func locate(_ name: String, loginShellPATH: String?) -> String? {
        if let o = overrides[name], fileExists(o) { return o }
        for d in searchPath(loginShellPATH: loginShellPATH) {
            let p = (d as NSString).appendingPathComponent(name)
            if fileExists(p) { return p }
        }
        return nil
    }

    /// Ask the user's login shell for its PATH (bounded by a timeout).
    public static func loginShellPATH(timeout: Double = 4) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf '%s' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    /// Environment for launching an agent: inherited env + merged PATH.
    public func environment(loginShellPATH: String?, extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath(loginShellPATH: loginShellPATH).joined(separator: ":")
        for (k, v) in extra { env[k] = v }
        return env
    }
}
