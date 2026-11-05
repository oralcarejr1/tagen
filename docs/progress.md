# Progress

States: Not started · In progress · Implemented, unverified · Verified · Blocked by external dependency.
"Verified" below always names the verification level (L1 Linux unit/integration, L2 macOS CI compile+tests,
L3 packaged-app smoke on CI, L4 live GUI on a Mac with permissions, L5 physical-Mac manual).

| Phase | Status | Verified at | Blocked items |
|---|---|---|---|
| 0 Foundation | Verified | L1, L2 | — |
| 1 Screen awareness + selection | Implemented; logic L1/L2; OCR L2; AX selection extraction 5/5 live (fixture); real TextEdit/Safari/Finder AX + OCR + selection (live probe 13/13) | L1, L2, L4 | Third-party apps, model answers (L5) |
| 2 Visual guidance | Implemented; geometry/lifecycle L1; overlays render L2; AX anchor error 0 pt live (fixture); 0.5 pt on real TextEdit/Safari; AX-notification anchoring live | L1, L2, L4 | Multi-monitor/Retina/full-screen visual check (L5) |
| 3 Voice | Implemented; state machine/controller verified L1 with transcript fixtures; TTS ko/en produces audio on CI | L1, L2, L4 (TTS only) | Live mic/speech recognition (L5) |
| 4 Agent bridge | Implemented; verified against protocol fakes incl. real approval relay | L1, L2 | Real CLIs + auth on the Mac (L5) |
| 5 Computer use | Verified on the fixture app: live CI run 27/27 safe tasks, 5/5 safety, 0 unauthorized | L1, L2, L4 (fixture) | Third-party apps (L5) |
| 6 Integration/packaging | App, settings, onboarding, emergency stop, packaging, self-test, docs | L2, L3 (see test-results) | Notarization (needs Developer ID) |

## Phase details

### Phase 0
- Files: `Package.swift`, `scripts/linux/*`, `.github/workflows/ci.yml`, `scripts/macos/*`, `CLAUDE.md`, `docs/*`.
- Tests: CI runs Linux container + `macos-26` (Xcode 26.6).
- Next: keep CI green.

### Phase 1 — Screen awareness, selection actions
- Files: `TagenCore/Context/*`, `TagenCore/Models/*`, `TagenCore/Assistant/*`, `TagenMac/AXInspector.swift`,
  `MacContextProvider.swift`, `ScreenCapturer.swift`, `TextRecognizer.swift`.
- Tests: ContextPackagerTests, AnthropicClientTests, OpenAICompatibleClientTests, ModelRouterTests, OrchestratorTests,
  GuideParserTests, MacPlatformTests (Vision OCR ko/en, downscale geometry).
- Still required: live AX extraction over real apps; selected-text success rate (`tagen-gui-check` measures 5 cases).

### Phase 2 — Visual guidance
- Files: `TagenCore/Geometry/*`, `TagenCore/Guidance/Annotation.swift`, `TagenMac/OverlayController.swift`.
- Tests: GeometryTests (multi-monitor, negative origins, Retina/fractional scale, capture/Vision mapping),
  AnnotationGeometryTests, AnnotationLifecycleTests, WorkflowTests.W3, MacPlatformTests.overlay.
- Still required: on-screen visual check with multiple physical monitors and full-screen apps.

### Phase 3 — Voice
- Files: `TagenCore/Voice/*`, `TagenMac/MacSpeech.swift`, hotkeys.
- Tests: VoiceStateMachineTests, VoiceControllerTests (fixture recognizer/synth), WorkflowTests.W4,
  MacPlatformTests.speech refusal without authorization.
- Still required: live push-to-talk ko/en, on-device availability, TTS voices.

### Phase 4 — Coding agents
- Files: `Sources/TagenAgents/*`, `Sources/tagen-approval-mcp`, `Sources/tagen-cli`.
- Tests: ClaudeCodeAdapterTests, CodexAppServerAdapterTests, CodexExecAdapterTests, ApprovalRelayTests, AgentInfrastructureTests.
- Still required: run against installed `claude` and `codex` on the Mac; confirm schemas (see research notes).

### Phase 5 — Computer use
- Files: `TagenCore/ComputerUse/*`, `TagenMac/MacGUIDriver.swift`, `Sources/TagenFixtureApp`, `Sources/tagen-gui-check`.
- Tests: ActionPolicyTests, ActionExecutorTests, ComputerUseSessionTests, WorkflowTests.W10 (simulated UI).
- Live (CI runner, fixture app): 27/27 safe, 5/5 safety, 0 unauthorized (run 41951686032).
- Still required: Act mode with a real model planner against third-party apps (P15).

### Phase 6 — Integration & delivery
- Files: `Sources/Tagen/*`, packaging scripts, docs.
- Tests: SelfTest on packaged app (persistence, settings, router, displays, permissions report, CLI discovery,
  relay helper bundled, overlay render, panel latency), bundle verification.
- Still required: physical-Mac checklist in `docs/test-results.md`.
