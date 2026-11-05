import Foundation

public enum ChatRole: String, Sendable, Codable { case user, assistant }

public enum ContentPart: Sendable, Equatable {
    case text(String)
    case image(data: Data, mediaType: String)
}

public struct ChatMessage: Sendable, Equatable {
    public var role: ChatRole
    public var parts: [ContentPart]
    /// Provider-native content (e.g. the Anthropic content-block array including thinking
    /// blocks and signatures). When present it is replayed verbatim so the conversation stays
    /// append-only, which current Claude models require for thinking-block validity.
    public var providerContent: JSONValue?
    public var providerID: String?

    public init(role: ChatRole, parts: [ContentPart], providerContent: JSONValue? = nil, providerID: String? = nil) {
        self.role = role; self.parts = parts; self.providerContent = providerContent; self.providerID = providerID
    }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, parts: [.text(text)]) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, parts: [.text(text)]) }

    public var text: String {
        parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }
    public var hasImage: Bool { parts.contains { if case .image = $0 { return true } else { return false } } }
}

/// What a request is for; drives routing and effort.
public enum ModelPurpose: String, Sendable, Codable, CaseIterable {
    case quickAnswer      // selection actions, short Q&A
    case screenQuestion   // contextual Ask, may include an image
    case guidance         // Guide mode, structured annotation output
    case computerUse      // Act-mode planning
}

public enum Effort: String, Sendable, Codable { case low, medium, high, xhigh, max }

public struct ChatRequest: Sendable, Equatable {
    public var system: String
    public var messages: [ChatMessage]
    public var maxTokens: Int
    public var purpose: ModelPurpose
    public var effort: Effort?
    public var timeout: Double
    /// Multi-turn requests whose history is reused next turn: enables automatic prompt caching of the
    /// conversation tail. One-shot requests leave it off to avoid paying cache writes nobody reads.
    public var cacheConversation: Bool

    public init(system: String, messages: [ChatMessage], maxTokens: Int = 16000, purpose: ModelPurpose,
                effort: Effort? = nil, timeout: Double = 120, cacheConversation: Bool = false) {
        self.system = system; self.messages = messages; self.maxTokens = maxTokens
        self.purpose = purpose; self.effort = effort; self.timeout = timeout; self.cacheConversation = cacheConversation
    }

    public var needsVision: Bool { messages.contains(where: \.hasImage) }
}

public struct TokenUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens
    }
}

public struct ChatResponse: Sendable, Equatable {
    public var text: String
    public var stopReason: String?
    public var model: String
    public var usage: TokenUsage
    /// Assistant message to append to the conversation (carries provider-native content).
    public var message: ChatMessage

    public init(text: String, stopReason: String?, model: String, usage: TokenUsage, message: ChatMessage? = nil) {
        self.text = text; self.stopReason = stopReason; self.model = model; self.usage = usage
        self.message = message ?? .assistant(text)
    }
}

public enum ModelStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case completed(ChatResponse)
}

public enum ModelError: Error, Sendable, Equatable, CustomStringConvertible {
    case notConfigured(String)
    case authentication(String)
    case permission(String)
    case rateLimited(retryAfter: Double?)
    case overloaded
    case server(status: Int, message: String)
    case invalidRequest(String)
    case refusal(category: String?)
    case network(String)
    case timeout
    case cancelled
    case decoding(String)

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .network, .timeout: return true
        case .server(let s, _): return s >= 500
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .notConfigured(let m): return "Model provider not configured: \(m)"
        case .authentication(let m): return "Authentication failed: \(m)"
        case .permission(let m): return "Permission denied by provider: \(m)"
        case .rateLimited(let r): return "Rate limited" + (r.map { " (retry after \(Int($0))s)" } ?? "")
        case .overloaded: return "Provider overloaded"
        case .server(let s, let m): return "Server error \(s): \(m)"
        case .invalidRequest(let m): return "Invalid request: \(m)"
        case .refusal(let c): return "The model declined this request" + (c.map { " (\($0))" } ?? "")
        case .network(let m): return "Network error: \(m)"
        case .timeout: return "Model request timed out"
        case .cancelled: return "Cancelled"
        case .decoding(let m): return "Could not decode model response: \(m)"
        }
    }

    /// Localized, user-facing explanation.
    public func userMessage(_ lang: LanguageCode) -> String {
        switch (self, lang) {
        case (.notConfigured(let m), .korean) where m.hasPrefix("Claude Code"):
            return "Claude Code CLI를 찾을 수 없습니다. Claude Code를 설치하거나 설정 > 에이전트에서 경로를 지정하세요."
        case (.notConfigured(let m), _) where m.hasPrefix("Claude Code"):
            return "Claude Code CLI was not found. Install Claude Code or set its path in Settings › Agents."
        case (.authentication(let m), .korean) where m.hasPrefix("Claude Code"):
            return "Claude Code에 로그인되어 있지 않습니다. 설정 > 에이전트에서 Claude Code 로그인을 하세요."
        case (.authentication(let m), _) where m.hasPrefix("Claude Code"):
            return "Claude Code is not signed in. Use Sign in… for Claude Code in Settings › Agents."
        case (.notConfigured(let m), .korean) where m.hasPrefix("Codex"):
            return "Codex CLI를 찾을 수 없습니다. Codex를 설치하거나 설정 > 에이전트에서 경로를 지정하세요."
        case (.notConfigured(let m), _) where m.hasPrefix("Codex"):
            return "Codex CLI was not found. Install Codex or set its path in Settings › Agents."
        case (.authentication(let m), .korean) where m.hasPrefix("Codex"):
            return "Codex에 로그인되어 있지 않습니다. 설정 > 에이전트에서 Codex 로그인을 하세요."
        case (.authentication(let m), _) where m.hasPrefix("Codex"):
            return "Codex is not signed in. Use Sign in… for Codex in Settings › Agents."
        case (.notConfigured, .korean): return "모델 API 키가 설정되지 않았습니다. 설정 > 모델에서 키를 입력하세요."
        case (.authentication, .korean): return "API 인증에 실패했습니다. 설정에서 API 키를 확인하세요."
        case (.rateLimited, .korean), (.overloaded, .korean): return "모델 서비스가 혼잡합니다. 잠시 후 다시 시도하세요."
        case (.network, .korean): return "네트워크 연결을 확인하세요."
        case (.timeout, .korean): return "모델 응답 시간이 초과되었습니다."
        case (.refusal, .korean): return "모델이 이 요청에 응답하지 않았습니다."
        case (.cancelled, .korean): return "취소되었습니다."
        case (_, .korean): return "오류가 발생했습니다: \(description)"
        case (.notConfigured, _): return "No model API key is configured. Add one in Settings › Models."
        default: return description
        }
    }
}

/// A model provider client.
public protocol ModelClient: Sendable {
    var providerName: String { get }
    func stream(_ request: ChatRequest, model: String) -> AsyncThrowingStream<ModelStreamEvent, Error>
}

extension ModelClient {
    /// Convenience: collect a streamed response.
    public func complete(_ request: ChatRequest, model: String, onDelta: (@Sendable (String) -> Void)? = nil) async throws -> ChatResponse {
        for try await ev in stream(request, model: model) {
            switch ev {
            case .textDelta(let t): onDelta?(t)
            case .completed(let r): return r
            }
        }
        throw ModelError.decoding("stream ended without completion")
    }
}
