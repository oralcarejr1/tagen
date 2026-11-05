import Foundation

public enum ProviderKind: String, Sendable, Codable, CaseIterable {
    case anthropic
    case openAICompatible
    /// The user's Claude subscription via the Claude Code CLI (no API key; see ClaudeCLIModelClient).
    case claudeCLI
    /// The user's ChatGPT subscription via the Codex CLI (no API key; see CodexCLIModelClient).
    case codexCLI
}

/// User-editable model configuration (persisted in settings; keys live in the SecretStore).
public struct ModelSettings: Sendable, Codable, Equatable {
    public struct Route: Sendable, Codable, Equatable {
        public var provider: ProviderKind
        public var model: String
        public var effort: Effort?
        public init(provider: ProviderKind, model: String, effort: Effort? = nil) {
            self.provider = provider; self.model = model; self.effort = effort
        }
    }
    public var routes: [ModelPurpose: Route]
    public var fallback: Route?
    public var openAIBaseURL: String
    public var openAIProviderName: String
    public var requestTimeout: Double
    public var enableRefusalFallback: Bool

    public init(routes: [ModelPurpose: Route], fallback: Route? = nil, openAIBaseURL: String = "https://api.openai.com/v1",
                openAIProviderName: String = "OpenAI-compatible", requestTimeout: Double = 120, enableRefusalFallback: Bool = true) {
        self.routes = routes; self.fallback = fallback; self.openAIBaseURL = openAIBaseURL
        self.openAIProviderName = openAIProviderName; self.requestTimeout = requestTimeout
        self.enableRefusalFallback = enableRefusalFallback
    }

    /// Defaults: Claude Opus 5.5 everywhere; lower effort for latency-sensitive routes.
    public static let `default` = ModelSettings(routes: [
        .quickAnswer: Route(provider: .anthropic, model: AnthropicClient.defaultModel, effort: .low),
        .screenQuestion: Route(provider: .anthropic, model: AnthropicClient.defaultModel, effort: .low),
        .guidance: Route(provider: .anthropic, model: AnthropicClient.defaultModel, effort: .medium),
        .computerUse: Route(provider: .anthropic, model: AnthropicClient.defaultModel, effort: .medium),
    ])

    /// Routes for a Claude subscription through the Claude Code CLI (model names are CLI aliases):
    /// Sonnet for latency-sensitive Ask/selection, Opus for Guide and Act planning.
    public static let claudeSubscriptionRoutes: [ModelPurpose: Route] = [
        .quickAnswer: Route(provider: .claudeCLI, model: "sonnet", effort: .low),
        .screenQuestion: Route(provider: .claudeCLI, model: "sonnet", effort: .low),
        .guidance: Route(provider: .claudeCLI, model: "opus", effort: .medium),
        .computerUse: Route(provider: .claudeCLI, model: "opus", effort: .medium),
    ]

    /// Routes for a ChatGPT subscription through the Codex CLI. An empty model uses the CLI's default.
    public static let chatGPTSubscriptionRoutes: [ModelPurpose: Route] = [
        .quickAnswer: Route(provider: .codexCLI, model: "", effort: .low),
        .screenQuestion: Route(provider: .codexCLI, model: "", effort: .low),
        .guidance: Route(provider: .codexCLI, model: "", effort: .medium),
        .computerUse: Route(provider: .codexCLI, model: "", effort: .medium),
    ]
}

/// Resolves which client/model serves a request and falls back on retryable failures.
public struct ModelRouter: Sendable {
    public let settings: ModelSettings
    let clients: [ProviderKind: ModelClient]

    public init(settings: ModelSettings, clients: [ProviderKind: ModelClient]) {
        self.settings = settings; self.clients = clients
    }

    public func route(for purpose: ModelPurpose) -> ModelSettings.Route {
        settings.routes[purpose] ?? ModelSettings.default.routes[purpose]!
    }

    /// Streams a response from the primary route, falling back to `settings.fallback` if the
    /// primary fails before producing any text with a retryable or auth/config error.
    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let primary = route(for: request.purpose)
        var req = request
        if req.effort == nil { req.effort = primary.effort }
        req.timeout = settings.requestTimeout
        let candidates = [primary] + (settings.fallback.map { [$0] } ?? [])
        let clients = self.clients
        let finalReq = req
        return AsyncThrowingStream { continuation in
            let task = Task {
                var lastError: Error = ModelError.notConfigured("no provider")
                for (i, route) in candidates.enumerated() {
                    guard let client = clients[route.provider] else {
                        lastError = ModelError.notConfigured(route.provider.rawValue); continue
                    }
                    var r = finalReq
                    if i > 0 { r.effort = route.effort }
                    var emitted = false
                    do {
                        for try await ev in client.stream(r, model: route.model) {
                            if case .textDelta = ev { emitted = true }
                            continuation.yield(ev)
                        }
                        continuation.finish(); return
                    } catch let e as ModelError {
                        lastError = e
                        let canFallback = !emitted && (e.isRetryable || { if case .notConfigured = e { return true }; return false }())
                        if !canFallback { break }
                    } catch {
                        lastError = error
                        if emitted { break }
                    }
                }
                continuation.finish(throwing: lastError)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ModelPurpose: CodingKeyRepresentable {}

/// Anything that can stream a model response for a request (ModelRouter, test doubles).
public protocol ModelStreaming: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ModelStreamEvent, Error>
}
extension ModelRouter: ModelStreaming {}
