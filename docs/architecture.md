# Tagen architecture

Modular monolith in one Swift package (swift-tools 6.0, Swift 6 language mode, macOS 14+).
Business logic lives in platform-independent modules behind protocols; macOS specifics are injected at the edge.

```
┌──────────────────────────── Tagen.app (SwiftUI + AppKit) ────────────────────────────┐
│ StatusBarController · AssistantPanel (Ask/Guide/Act, voice, selection, agents, history) │
│ SettingsView (permissions onboarding, models, privacy, voice, agents, computer use)     │
│ AppController (composition root) · PanelApprovalPresenter · SelfTest (--self-test)      │
└──────────┬───────────────────────────────┬───────────────────────────┬──────────────────┘
           │                               │                           │
┌──────────▼──────────┐   ┌────────────────▼───────────────┐  ┌───────▼────────────────┐
│ TagenMac (macOS)    │   │ TagenCore (platform-independent)│  │ TagenAgents (portable) │
│ AXInspector         │──▶│ ScreenContextProvider (proto)   │  │ ClaudeCodeAdapter      │
│ MacContextProvider  │   │ ContextPackager · Redactor      │  │ CodexAppServerAdapter  │
│ ScreenCapturer(SCK) │   │ ModelRouter → AnthropicClient,  │  │ CodexExecAdapter       │
│ TextRecognizer(VN)  │   │   OpenAICompatibleClient        │  │ AgentTaskManager       │
│ OverlayController   │──▶│ AssistantOrchestrator, Prompts  │  │ ApprovalRelayServer ◀──┼─ tagen-approval-mcp
│ MacSpeech (SF/AV)   │──▶│ GuideParser · AnnotationLifecycle│ │ ExecutableLocator/Auth │   (stdio MCP)
│ MacGUIDriver(AX/CG) │──▶│ ActionExecutor · ActionPolicy   │  │ JSONLProcess           │
│ MacPermissionChecker│──▶│ ComputerUseSession · Planner    │  └────────────────────────┘
│ KeychainSecretStore │──▶│ VoiceStateMachine · Controller  │
│ GlobalHotkeys       │   │ ApprovalBroker · EmergencyStop  │
└─────────────────────┘   │ AppStore (SQLite) · Geometry    │
                          └─────────────────────────────────┘
```

## Key flows
**Ask about the screen** — hotkey → panel → `AssistantOrchestrator.ask` → `MacContextProvider.capture`
(AX tree of the focused window of the *last non-Tagen* app, selection, URL; screenshot only if policy/heuristics require;
OCR when AX text is thin) → `ContextPackager` (element ids, masked secure fields, redaction, `<untrusted_content>`
wrapper) → `ModelRouter` (streaming) → panel. Follow-ups reuse the conversation; unchanged screens are not resent.

**Append-only model history** — the system prompt is frozen per conversation; per-turn context and mode instructions
go into user turns; Anthropic assistant turns keep their raw content blocks (thinking + signatures) and are replayed
verbatim. Only whole leading turns are dropped when trimming.

**Guide** — model returns JSON (`element_id` preferred, screenshot `box` fallback) → `GuideParser` validates ids/boxes →
`Annotation`s anchored to `ElementIdentity` → `OverlayController` renders per display; `AnnotationLifecycle` re-reads AX
frames ~8×/s, follows moves, drops annotations whose target vanished, whose window resized/closed, or that expired.

**Coordinate spaces** (`DisplayLayout`, `CaptureGeometry`): global (top-left of primary, points; AX/CG/SCK) ↔ Cocoa
(bottom-left) ↔ display-local ↔ pixels (×scale) ↔ screenshot/model pixels (incl. downscale) ↔ Vision normalized
(bottom-left). All conversions are unit tested, including negative-origin secondary displays and fractional scales.

**Selection actions** — `kAXSelectedTextAttribute` (no clipboard access) or region OCR → explain/summarize/translate
(ko↔en)/rewrite/custom → result panel; *Replace selection* requires an explicit click **and** an approval, re-checks
that the selection is unchanged, writes via AX and verifies.

**Voice** — Carbon hotkey press/release → `VoiceController` (pure `VoiceStateMachine`) → `MacSpeechRecognizer`
(partials, on-device preferred, audio only while held, never stored) → orchestrator → `MacSpeechSynthesizer`.
Pressing talk while thinking/speaking interrupts; Esc/stop cancels; typed input is the fallback.

**Coding agents** — `AgentTaskManager` → adapter → `JSONLProcess` (CLI on the user's Mac, PATH merged from the login
shell) → typed `AgentEvent`s (progress, tools, approvals, result) → panel + SQLite. Approvals flow through
`ApprovalBroker` (Claude Code via `--permission-prompt-tool` → `tagen-approval-mcp` → Unix socket; Codex via app-server
server requests). Cancel = `turn/interrupt` / SIGINT→SIGTERM→SIGKILL. Resume via session/thread id; one automatic
resume after crashes. CLI sandboxes and permission modes are never bypassed.

**Computer use** — `ComputerUseSession`: user approves goal + target app → loop: observe → planner (model JSON, or
scripted) → `ActionExecutor`: Observe → Identify (query / snapshot id / point bound to an observation) → Validate →
Authorize (`ActionPolicy` risk; prohibited never asked; high always asked) → Execute (AX first, CGEvent fallback) →
Observe again → Verify (value/toggle/state change). Bounded retries only for idempotent actions, always from a fresh
observation; stale coordinates are refused; user mouse/keyboard activity pauses automation.

**Security** — separate permission gates per capability (`PermissionGate`), onboarding UI using only system prompts /
System Settings, `EmergencyStop` (⌃⌥⌘. / menu / panel button) cancels model calls, speech, agents, automation and
overlays; Keychain for credentials; redaction everywhere text is persisted or logged; screen content is untrusted data.

## Additions after the first delivery
- **Prompt caching** — frozen system prompt carries an explicit `cache_control` breakpoint; multi-turn requests
  (Ask/Guide follow-ups, Act planner) add top-level automatic caching so each turn reads the previous ones from cache.
  One-shot selection actions don't write cache. `TokenUsage` reports cache read/write tokens.
- **Act planner** — compact per-step tree (`ContextPackager.Options.planner`), "changes since previous step"
  (`ObservationDiff`), screenshot attached when accessibility is thin or on `{"type":"screenshot"}`; `image_point`
  targets are converted through the screenshot's `CaptureGeometry`. Per-task model-token budget (`maxModelTokens`).
- **Conversation resume** — History › "Continue this conversation" restores the stored transcript as untrusted text in
  a fresh model context (no fabricated earlier turns, so append-only history stays valid); new turns append to the same record.
- **Configurable shortcuts** — `HotkeyBindings` (defaults, validation: conflicts, modifier rules, emergency stop required;
  Carbon masks), re-registered on save; menu bar shows current bindings. Mic button context menu switches ko/en recognition.
- **AX performance & anchoring** — snapshot time budget (default 0.8 s → "truncated"); overlays re-anchor on
  `AXObserver` move/resize/destroy notifications (`AXChangeObserver`), with polling kept at 0.5 s as a safety net.
- **Codex / Claude Code** — adapters verified against codex-cli 0.166.0's generated schema + live `codex app-server`, and
  against the Claude Agent SDK 0.3.318 types (see `docs/research/codex-claude-protocols.md`).
- **Localized approvals** — `ApprovalRequest` keeps canonical English (audit/logs) plus optional Korean
  `ApprovalText`; `ActionPolicy` emits index-aligned ko/en reasons; `ActionExecutor.approvalRequest` names the target in
  plain language (`AXRoleName`, `GUIAction.summary(_:targetName:)`) instead of element ids or AX roles.
- **CI artifacts** — `Tagen --render-ui <dir>` renders panel/settings screens; `tagen-live-probe` measures real apps;
  both are published to the `ci-artifacts` branch.

## Verification levels
1. Unit + integration tests on Linux (Docker, Swift 6.2) — TagenCore, TagenAgents (fake CLIs, real relay binary).
2. macOS CI compile + the same tests + TagenMacTests (OCR, Keychain, display layout, overlay) on `macos-26`.
3. Packaged-app smoke test (`Tagen --self-test`) and bundle verification on CI.
4. Live GUI check (`tagen-gui-check` vs `TagenFixture`) — needs Accessibility permission; reports *blocked* otherwise.
5. Physical-Mac checklist (`docs/test-results.md`).
