import Foundation

/// Credentials storage. The macOS app uses the Keychain (TagenMac.KeychainSecretStore);
/// secrets are never written to SQLite, UserDefaults or logs.
public protocol SecretStore: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ key: String, value: String) throws
    func delete(_ key: String) throws
}

public enum SecretKey {
    public static let anthropicAPIKey = "anthropic.apiKey"
    public static let openAIAPIKey = "openai.apiKey"
    /// Optional explicit credentials handed to agent CLIs as environment variables.
    public static let claudeCodeOAuthToken = "claudecode.oauthToken"
    public static let codexAPIKey = "codex.apiKey"
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let store = Locked<[String: String]>([:])
    public init(_ initial: [String: String] = [:]) { store.set(initial) }
    public func get(_ key: String) throws -> String? { store.current[key] }
    public func set(_ key: String, value: String) throws { store.withLock { $0[key] = value } }
    public func delete(_ key: String) throws { store.withLock { $0[key] = nil } }
}
