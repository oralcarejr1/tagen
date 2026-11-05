import Foundation

public enum AssistantMode: String, Sendable, Codable, CaseIterable { case ask, guide, act }

public enum ResponseLanguagePreference: String, Sendable, Codable, CaseIterable { case auto, korean, english
    public func resolve(for input: String) -> LanguageCode {
        switch self {
        case .korean: return .korean
        case .english: return .english
        case .auto: return LanguageDetector.detect(input)
        }
    }
}

public struct AssistantSettings: Sendable, Codable, Equatable {
    public var screenshotPolicy: ContextRequest.ScreenshotPolicy = .ifNeeded
    /// When false, screenshots are never sent to a model provider (AX/OCR text only).
    public var allowScreenshotsToModel: Bool = true
    public var responseLanguage: ResponseLanguagePreference = .auto
    public var guideAnnotationTTL: Double = 45
    public var maxHistoryTurns: Int = 20
    public init() {}
}

public struct ContextSummary: Sendable, Equatable {
    public var appName: String?
    public var windowTitle: String?
    public var elementCount: Int
    public var hasSelection: Bool
    public var usedScreenshot: Bool
    public var screenshotReason: String?
    public var reusedPrevious: Bool
    public var limitations: [String]
    public init(appName: String?, windowTitle: String?, elementCount: Int, hasSelection: Bool, usedScreenshot: Bool,
                screenshotReason: String?, reusedPrevious: Bool, limitations: [String]) {
        self.appName = appName; self.windowTitle = windowTitle; self.elementCount = elementCount; self.hasSelection = hasSelection
        self.usedScreenshot = usedScreenshot; self.screenshotReason = screenshotReason; self.reusedPrevious = reusedPrevious
        self.limitations = limitations
    }
}

public enum AssistantEvent: Sendable, Equatable {
    case status(String)
    case context(ContextSummary)
    case textDelta(String)
    case guidance(GuideReply)
    case completed(answer: String)
    case replacementReady(text: String, selection: SelectedText)
}

public enum AssistantError: Error, Sendable, Equatable, CustomStringConvertible {
    case noSelection
    case busy
    case contextUnavailable(String)
    case model(ModelError)
    case stopped
    public var description: String {
        switch self {
        case .noSelection: return "No selected text found. Select text, or draw a region to read."
        case .busy: return "Another request is running."
        case .contextUnavailable(let m): return "Could not read the screen: \(m)"
        case .model(let e): return e.description
        case .stopped: return "Stopped."
        }
    }
}

/// Conversation state kept append-only for the model (see ChatMessage.providerContent).
public struct ConversationState: Sendable {
    public var id: UUID = UUID()
    public var recordID: UUID?
    public var messages: [ChatMessage] = []
    public var lastFingerprint: String?
    public var lastContext: ScreenContext?
    public init() {}
}

/// Central coordinator for Ask / Guide / selection actions. Act mode is delegated to
/// `ComputerUseSession`; coding agents to `TagenAgents`.
public actor AssistantOrchestrator {
    let contextProvider: ScreenContextProvider?
    let models: ModelStreaming
    let store: AppStore?
    let packager: ContextPackager
    let stop: EmergencyStop
    public var settings: AssistantSettings
    public private(set) var conversation = ConversationState()
    private var currentTask: Task<Void, Never>?
    private var stopToken: UUID?

    public init(contextProvider: ScreenContextProvider?, models: ModelStreaming, store: AppStore?, settings: AssistantSettings = AssistantSettings(),
                packager: ContextPackager = ContextPackager(), stop: EmergencyStop = .shared) {
        self.contextProvider = contextProvider; self.models = models; self.store = store
        self.settings = settings; self.packager = packager; self.stop = stop
    }

    public func updateSettings(_ s: AssistantSettings) { settings = s }

    public func newConversation() { cancel(); conversation = ConversationState() }

    public func cancel() { currentTask?.cancel(); currentTask = nil }

    public var isBusy: Bool { currentTask != nil }

    public var lastContext: ScreenContext? { conversation.lastContext }

    // MARK: Ask / Guide

    public func ask(_ question: String, mode: AssistantMode, region: Rect? = nil) -> AsyncThrowingStream<AssistantEvent, Error> {
        start { orchestrator, emit in
            try await orchestrator.performAsk(question, mode: mode, region: region, emit: emit)
        }
    }

    // MARK: Selection actions

    public func runSelectionAction(_ action: SelectionAction, selection provided: SelectedText? = nil) -> AsyncThrowingStream<AssistantEvent, Error> {
        start { orchestrator, emit in
            try await orchestrator.performSelection(action, provided: provided, emit: emit)
        }
    }

    // MARK: internals

    private func start(_ body: @escaping @Sendable (AssistantOrchestrator, @escaping @Sendable (AssistantEvent) -> Void) async throws -> Void)
        -> AsyncThrowingStream<AssistantEvent, Error>
    {
        cancel()
        let (stream, continuation) = AsyncThrowingStream<AssistantEvent, Error>.makeStream()
        let gen = stop.currentGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            let token = self.stop.register { _ in continuation.finish(throwing: AssistantError.stopped) }
            defer { self.stop.unregister(token) }
            do {
                try self.stop.check(sinceGeneration: gen)
                try await body(self, { continuation.yield($0) })
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: AssistantError.stopped)
            } catch ModelError.cancelled {
                continuation.finish(throwing: AssistantError.stopped)
            } catch let e as ModelError {
                continuation.finish(throwing: AssistantError.model(e))
            } catch is EmergencyStopError {
                continuation.finish(throwing: AssistantError.stopped)
            } catch {
                continuation.finish(throwing: error)
            }
            await self.taskFinished()
        }
        currentTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func taskFinished() { currentTask = nil }

    func captureContext(question: String, region: Rect?, includeSelection: Bool) async throws -> ScreenContext {
        guard let provider = contextProvider else { return ScreenContext(limitations: ["screen context provider unavailable"]) }
        var policy = settings.screenshotPolicy
        if !settings.allowScreenshotsToModel { policy = .never }
        let req = ContextRequest(includeAccessibility: true, includeSelection: includeSelection, includeScreenshot: policy, region: region)
        do { return try await provider.capture(req) }
        catch { throw AssistantError.contextUnavailable(String(describing: error)) }
    }

    func performAsk(_ question: String, mode: AssistantMode, region: Rect?, emit: @escaping @Sendable (AssistantEvent) -> Void) async throws {
        emit(.status("Reading screen…"))
        let ctx = try await captureContext(question: question, region: region, includeSelection: true)
        try Task.checkCancellation()
        var policy = settings.allowScreenshotsToModel ? settings.screenshotPolicy : .never
        if region != nil && settings.allowScreenshotsToModel { policy = .always }
        let pkg = packager.package(ctx, question: question, policy: policy)
        let fp = Self.fingerprint(ctx, pkg)
        let reuse = fp == conversation.lastFingerprint && pkg.image == nil && mode != .guide
        emit(.context(ContextSummary(appName: ctx.app?.name, windowTitle: ctx.window?.title, elementCount: pkg.includedElementIDs.count,
                                     hasSelection: ctx.selection != nil, usedScreenshot: pkg.image != nil, screenshotReason: pkg.usedImageReason,
                                     reusedPrevious: reuse, limitations: ctx.limitations)))

        var parts: [ContentPart] = []
        if let img = pkg.image { parts.append(.image(data: img.data, mediaType: img.mediaType)) }
        let contextText = reuse ? "(Screen unchanged since the previous message.)" : pkg.text
        let instruction = mode == .guide ? PromptLibrary.guideInstruction(question: question) : PromptLibrary.askInstruction(question: question)
        parts.append(.text(contextText + "\n\n" + instruction))
        let userMsg = ChatMessage(role: .user, parts: parts)

        let request = ChatRequest(system: PromptLibrary.systemPrompt, messages: trimmedHistory() + [userMsg],
                                  maxTokens: mode == .guide ? 4000 : 16000, purpose: mode == .guide ? .guidance : .screenQuestion,
                                  cacheConversation: true)
        emit(.status("Thinking…"))
        let response = try await streamModel(request, emitDeltas: mode != .guide, emit: emit)
        if response.usage.cacheReadTokens > 0 || response.usage.cacheWriteTokens > 0 {
            Log("orchestrator").debug("cache read=\(response.usage.cacheReadTokens) write=\(response.usage.cacheWriteTokens) uncached=\(response.usage.inputTokens)")
        }

        conversation.messages.append(userMsg)
        conversation.messages.append(response.message)
        conversation.lastFingerprint = fp
        conversation.lastContext = ctx
        persist(question: question, answer: response.text, mode: mode, hadImage: pkg.image != nil)

        if mode == .guide {
            let reply = GuideParser.parse(response.text, context: ctx, ttl: settings.guideAnnotationTTL)
            emit(.guidance(reply))
            emit(.completed(answer: reply.answer))
        } else {
            emit(.completed(answer: response.text))
        }
    }

    func performSelection(_ action: SelectionAction, provided: SelectedText?, emit: @escaping @Sendable (AssistantEvent) -> Void) async throws {
        var selection = provided
        if selection == nil {
            emit(.status("Reading selection…"))
            let ctx = try await captureContext(question: "", region: nil, includeSelection: true)
            selection = ctx.selection
        }
        guard let sel = selection, !sel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.noSelection }
        let lang = settings.responseLanguage.resolve(for: sel.text)
        let prompt = PromptLibrary.selectionInstruction(action, text: sel.text, responseLanguage: lang)
        let request = ChatRequest(system: PromptLibrary.systemPrompt, messages: [.user(prompt)], maxTokens: 8000, purpose: .quickAnswer)
        emit(.status("Working…"))
        let response = try await streamModel(request, emitDeltas: true, emit: emit)
        persist(question: "\(action.title): \(sel.text.prefix(200))", answer: response.text, mode: AssistantMode.ask, hadImage: false)
        emit(.completed(answer: response.text))
        if action.producesReplacement && sel.isEditable && sel.source == .accessibility {
            emit(.replacementReady(text: Self.cleanReplacement(response.text), selection: sel))
        }
    }

    func streamModel(_ request: ChatRequest, emitDeltas: Bool, emit: @escaping @Sendable (AssistantEvent) -> Void) async throws -> ChatResponse {
        var final: ChatResponse?
        for try await ev in models.stream(request) {
            try Task.checkCancellation()
            switch ev {
            case .textDelta(let t): if emitDeltas { emit(.textDelta(t)) }
            case .completed(let r): final = r
            }
        }
        // A cancelled consumer ends the stream without an error; report it as cancellation.
        try Task.checkCancellation()
        guard let r = final else { throw ModelError.decoding("no completion") }
        return r
    }

    /// Keep at most N recent turns. Drops whole leading user/assistant pairs only (the
    /// front of the history), which keeps the remaining prefix intact.
    func trimmedHistory() -> [ChatMessage] {
        let maxMsgs = settings.maxHistoryTurns * 2
        guard conversation.messages.count > maxMsgs else { return conversation.messages }
        var msgs = Array(conversation.messages.suffix(maxMsgs))
        if msgs.first?.role == .assistant { msgs.removeFirst() }
        return msgs
    }

    func persist(question: String, answer: String, mode: AssistantMode, hadImage: Bool) {
        guard let store else { return }
        do {
            if conversation.recordID == nil {
                conversation.recordID = try store.createConversation(title: String(question.prefix(80)), mode: mode.rawValue).id
            }
            if let id = conversation.recordID {
                _ = try store.appendMessage(conversationID: id, role: .user, text: question, hadImage: hadImage)
                _ = try store.appendMessage(conversationID: id, role: .assistant, text: answer, hadImage: false)
            }
        } catch {
            Log("orchestrator").warning("persist failed: \(error)")
        }
    }

    static func fingerprint(_ ctx: ScreenContext, _ pkg: ContextPackager.Package) -> String {
        var h = Hasher()
        h.combine(ctx.app?.bundleID); h.combine(ctx.window?.title); h.combine(ctx.window?.frame)
        h.combine(pkg.text); h.combine(ctx.selection?.text)
        return String(h.finalize())
    }

    /// Strip common wrappers models add around rewritten text.
    public static func cleanReplacement(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            var lines = t.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 2 { lines.removeFirst(); if lines.last?.hasPrefix("```") == true { lines.removeLast() } }
            t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (o, c) in [("\"", "\""), ("“", "”"), ("'", "'")] where t.count > 2 && t.hasPrefix(o) && t.hasSuffix(c) && t.filter({ String($0) == o }).count <= 2 {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }
}
