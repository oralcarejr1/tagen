import XCTest
@testable import TagenCore

final class OrchestratorTests: XCTestCase {
    func ctx(selection: SelectedText? = nil, image: Bool = false) -> ScreenContext {
        var c = ScreenContext(app: AppInfo(name: "TagenFixture", bundleID: "dev.tagen.Fixture", pid: 7),
                              window: WindowInfo(title: "Tagen Fixture", frame: Rect(x: 100, y: 100, width: 560, height: 620)),
                              axRoot: Fixtures.fixtureTree(), selection: selection, layout: Fixtures.layout)
        if image {
            c.image = CapturedImage(data: Data([0xFF]), mediaType: "image/jpeg",
                                    geometry: CaptureGeometry(captureRect: Rect(x: 100, y: 100, width: 560, height: 620), imageSize: Size(width: 1120, height: 1240)))
        }
        return c
    }

    func collect(_ s: AsyncThrowingStream<AssistantEvent, Error>) async throws -> [AssistantEvent] {
        var out: [AssistantEvent] = []
        for try await e in s { out.append(e) }
        return out
    }

    func testAskStreamsAndKeepsAppendOnlyHistory() async throws {
        let model = ScriptedModel(["The counter is zero.", "Click Increment."])
        let o = AssistantOrchestrator(contextProvider: FakeContextProvider(ctx()), models: model, store: try AppStore.inMemory(), stop: EmergencyStop())
        let e1 = try await collect(await o.ask("What does the counter show?", mode: .ask))
        XCTAssertTrue(e1.contains(.completed(answer: "The counter is zero.")))
        XCTAssertTrue(e1.contains { if case .textDelta = $0 { return true }; return false })
        let r1 = model.requests.current[0]
        XCTAssertEqual(r1.system, PromptLibrary.systemPrompt)
        XCTAssertTrue(r1.messages[0].text.contains("[w0.0] Button \"Increment\""))
        XCTAssertEqual(r1.purpose, .screenQuestion)
        XCTAssertTrue(r1.cacheConversation, "conversational asks enable prompt caching")

        let e2 = try await collect(await o.ask("How do I raise it?", mode: .ask))
        XCTAssertTrue(e2.contains(.completed(answer: "Click Increment.")))
        let r2 = model.requests.current[1]
        // History: identical system, first two messages replayed unchanged (incl. provider content).
        XCTAssertEqual(r2.system, r1.system)
        XCTAssertEqual(r2.messages.count, 3)
        XCTAssertEqual(r2.messages[0], r1.messages[0])
        XCTAssertNotNil(r2.messages[1].providerContent)
        // Unchanged screen → context not resent.
        XCTAssertTrue(r2.messages[2].text.contains("Screen unchanged"))
        if case .context(let c)? = e2.first(where: { if case .context = $0 { return true }; return false }) { XCTAssertTrue(c.reusedPrevious) } else { XCTFail() }
    }

    func testGuideModeProducesAnchoredAnnotations() async throws {
        let reply = #"Here: ```json {"answer":"Click Increment","annotations":[{"type":"arrow","element_id":"w0.0","label":"Click here"},{"type":"circle","element_id":"w9.9"},{"type":"highlight","box":[0,0,100,50]}]} ```"#
        let o = AssistantOrchestrator(contextProvider: FakeContextProvider(ctx(image: true)), models: ScriptedModel([reply]), store: nil, stop: EmergencyStop())
        let ev = try await collect(await o.ask("where is the increment button?", mode: .guide))
        guard case .guidance(let g)? = ev.first(where: { if case .guidance = $0 { return true }; return false }) else { return XCTFail("no guidance") }
        XCTAssertEqual(g.answer, "Click Increment")
        XCTAssertEqual(g.annotations.count, 2)
        XCTAssertEqual(g.annotations[0].targetFrame, Rect(x: 116, y: 140, width: 90, height: 24))
        if case .element(let id, _) = g.annotations[0].target { XCTAssertEqual(id.identifier, "incrementButton") } else { XCTFail() }
        // Screenshot box (pixels at 2x) → global points.
        XCTAssertEqual(g.annotations[1].targetFrame, Rect(x: 100, y: 100, width: 50, height: 25))
        XCTAssertEqual(g.rejected.count, 1)
        XCTAssertFalse(ev.contains { if case .textDelta = $0 { return true }; return false }, "raw JSON must not stream into the UI")
    }

    func testSelectionActionsAndReplacementProposal() async throws {
        let sel = SelectedText(text: "teh quick fox", source: .accessibility, isEditable: true)
        let model = ScriptedModel(["\"the quick fox\""])
        let o = AssistantOrchestrator(contextProvider: FakeContextProvider(ctx(selection: sel)), models: model, store: nil, stop: EmergencyStop())
        let ev = try await collect(await o.runSelectionAction(.rewrite(.fixGrammar)))
        XCTAssertTrue(ev.contains(.replacementReady(text: "the quick fox", selection: sel)))
        let prompt = model.requests.current[0].messages[0].text
        XCTAssertTrue(prompt.contains("<untrusted_content kind=\"selected_text\">"))
        XCTAssertEqual(model.requests.current[0].purpose, .quickAnswer)
        XCTAssertFalse(model.requests.current[0].cacheConversation, "one-shot selection actions don't write cache")
    }

    func testTranslateDirectionKoreanEnglish() {
        let ko = PromptLibrary.selectionInstruction(.translate(to: nil), text: "안녕하세요", responseLanguage: .korean)
        XCTAssertTrue(ko.contains("into English"))
        let en = PromptLibrary.selectionInstruction(.translate(to: nil), text: "Good morning", responseLanguage: .english)
        XCTAssertTrue(en.contains("into Korean"))
        XCTAssertTrue(PromptLibrary.selectionInstruction(.explain, text: "x", responseLanguage: .korean).contains("Respond in Korean"))
    }

    func testNoSelectionErrorAndNonEditableNoReplacement() async throws {
        let o = AssistantOrchestrator(contextProvider: FakeContextProvider(ctx()), models: ScriptedModel(["x"]), store: nil, stop: EmergencyStop())
        do { _ = try await collect(await o.runSelectionAction(.explain)); XCTFail() } catch { XCTAssertEqual(error as? AssistantError, .noSelection) }
        let ro = SelectedText(text: "read only", source: .accessibility, isEditable: false)
        let o2 = AssistantOrchestrator(contextProvider: FakeContextProvider(ctx(selection: ro)), models: ScriptedModel(["x"]), store: nil, stop: EmergencyStop())
        let ev = try await collect(await o2.runSelectionAction(.rewrite(.shorter)))
        XCTAssertFalse(ev.contains { if case .replacementReady = $0 { return true }; return false })
    }

    func testModelErrorsSurfaceAndCancellation() async throws {
        let o = AssistantOrchestrator(contextProvider: FakeContextProvider(ctx()), models: ScriptedModel(results: [.failure(.timeout)]), store: nil, stop: EmergencyStop())
        do { _ = try await collect(await o.ask("q", mode: .ask)); XCTFail() } catch { XCTAssertEqual(error as? AssistantError, .model(.timeout)) }

        let slow = AssistantOrchestrator(contextProvider: FakeContextProvider(ctx()), models: ScriptedModel(["late"], delayNanos: 3_000_000_000), store: nil, stop: EmergencyStop())
        let stream = await slow.ask("q", mode: .ask)
        Task { try? await Task.sleep(nanoseconds: 100_000_000); await slow.cancel() }
        let t0 = Date()
        do { _ = try await collect(stream); XCTFail() } catch { XCTAssertEqual(error as? AssistantError, .stopped) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
    }

    func testEmergencyStopHaltsRequest() async {
        let stop = EmergencyStop()
        let o = AssistantOrchestrator(contextProvider: FakeContextProvider(ctx()), models: ScriptedModel(["late"], delayNanos: 3_000_000_000), store: nil, stop: stop)
        let stream = await o.ask("q", mode: .ask)
        Task { try? await Task.sleep(nanoseconds: 100_000_000); stop.trigger(reason: "test") }
        do { for try await _ in stream {}; XCTFail() } catch { XCTAssertEqual(error as? AssistantError, .stopped) }
    }

    func testScreenshotsWithheldWhenDisallowed() async throws {
        var s = AssistantSettings(); s.allowScreenshotsToModel = false
        let model = ScriptedModel(["ok"])
        let o = AssistantOrchestrator(contextProvider: FakeContextProvider(ctx(image: true)), models: model, store: nil, settings: s, stop: EmergencyStop())
        _ = try await collect(await o.ask("what color is the button?", mode: .ask))
        XCTAssertFalse(model.requests.current[0].messages.last!.hasImage)
    }

    func testCleanReplacement() {
        XCTAssertEqual(AssistantOrchestrator.cleanReplacement("```\nfixed text\n```"), "fixed text")
        XCTAssertEqual(AssistantOrchestrator.cleanReplacement("“quoted”"), "quoted")
        XCTAssertEqual(AssistantOrchestrator.cleanReplacement("  plain  "), "plain")
    }

    func testHistoryPersistedRedacted() async throws {
        let store = try AppStore.inMemory()
        let o = AssistantOrchestrator(contextProvider: FakeContextProvider(ctx()), models: ScriptedModel(["answer"]), store: store, stop: EmergencyStop())
        _ = try await collect(await o.ask("my key is sk-ant-api03-ZZZZZZZZZZZZZZZZZZZZZZ", mode: .ask))
        let conv = try XCTUnwrap(store.conversations().first)
        let msgs = try store.messages(conversationID: conv.id)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertFalse(msgs[0].text.contains("ZZZZ"))
    }
}

final class GuideParserTests: XCTestCase {
    func testExtractJSONFromProse() {
        XCTAssertEqual(GuideParser.extractJSONObject(#"Sure! {"a": "x {y}"} trailing"#)?["a"]?.stringValue, "x {y}")
        XCTAssertNil(GuideParser.extractJSONObject("no json here"))
    }
    func testBoxOutsideImageRejected() {
        var c = ScreenContext(axRoot: Fixtures.fixtureTree(), layout: Fixtures.layout)
        c.image = CapturedImage(data: Data(), mediaType: "image/jpeg", geometry: CaptureGeometry(captureRect: Rect(x: 0, y: 0, width: 100, height: 100), imageSize: Size(width: 100, height: 100)))
        let r = GuideParser.parse(#"{"answer":"a","annotations":[{"type":"circle","box":[90,90,50,50]}]}"#, context: c)
        XCTAssertTrue(r.annotations.isEmpty); XCTAssertEqual(r.rejected.count, 1)
    }
}
