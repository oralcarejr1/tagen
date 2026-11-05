# Test results

Only results that were actually executed are recorded here. Verification levels:
**L1** Linux unit/integration (Docker `swift:6.2-noble`, Swift 6.2.4) · **L2** macOS CI (`macos-26`, Xcode 26.6) ·
**L3** packaged-app smoke on CI · **L4** live GUI automation · **L5** physical Mac (manual).

## L1 — Linux (cloud container), commit 279d0a9 + later
`scripts/linux/test.sh` → **151 tests, 0 failures** (latest, 5a145ce+; was 126 at 279d0a9). Earlier the suite (122 tests then) was repeated 5× with 0 failures
(flakiness check of subprocess/timing tests).

| Suite | What it proves |
|---|---|
| GeometryTests, AnnotationGeometryTests, AnnotationLifecycleTests | global↔Cocoa↔local↔pixel conversions on 2 displays (negative origin, 2× and 1×, fractional 1.5×); capture/downscale/Vision mapping; arrows stay on screen and point at target; annotations follow moved elements, are removed on disappearance/resize/expiry/off-screen; rendered anchor error 0 pt (target ≤ 12 pt) |
| ContextPackagerTests, RedactorTests, LanguageTests | AX rendering with ids, secure fields masked, secrets redacted, untrusted wrapper cannot be closed by screen text, AX-first screenshot policy (ko/en visual keywords, canvas apps), ko/en detection |
| AnthropicClientTests, OpenAICompatibleClientTests, SSEParserTests, ModelRouterTests | Messages API request shape (headers, image blocks, effort, refusal fallback), SSE streaming, thinking blocks preserved for append-only replay, retry on 429/529 only before output, no retry on 401, refusal/mid-stream errors, provider fallback |
| OrchestratorTests, GuideParserTests | Ask with follow-ups (append-only history, unchanged screen not resent), Guide JSON → anchored annotations (invalid ids/boxes rejected), selection actions + replacement proposal, ko↔en translate direction, cancellation and emergency stop → `stopped`, screenshots withheld when disallowed, redacted persistence |
| ActionPolicyTests, ActionExecutorTests, ComputerUseSessionTests | risk classification (destructive/financial/transmit/security words in en+ko, secure fields, secrets, terminals, credential stores & privacy settings prohibited, scope violations); full observe→verify trace; stale coordinates refused; stale ids re-resolved; disabled/ambiguous/missing targets refused; bounded retries; user-input conflict pause; approvals deny/approve; planner JSON loop; step/failure limits — **on a simulated UI, not live** |
| VoiceStateMachineTests, VoiceControllerTests | PTT transitions, partials, interrupt while thinking/speaking, cancel from every state, finalize timeout, recognition failure, text fallback, markdown stripped for TTS — with transcript fixtures (no audio hardware) |
| ClaudeCodeAdapterTests, CodexAppServerAdapterTests, CodexExecAdapterTests, ApprovalRelayTests, AgentInfrastructureTests | against deterministic fake CLIs: progress/tool streaming, results with cost/session, approvals end-to-end through the real `tagen-approval-mcp` + Unix-socket relay (allow/deny/read-only), Codex command/file/legacy approvals, auth failures, crash → automatic resume, cancel (SIGINT / `turn/interrupt`), resume args, persistence, emergency stop cancels agents |
| PersistenceTests, ApprovalBrokerTests, PermissionGateTests, CommandRiskTests, SupportTests | SQLite migrations/cascade/redaction, approval timeout/prohibited/task grants/emergency stop/audit, permission degradation, shell/tool risk |
| WorkflowTests | W3 locate+highlight follows window move (≤ 12 pt), W4 spoken question→spoken answer, W10 permission revoked mid-task, **100 mixed sessions (ask/guide/selection/act/cancel) with 0 crashes** (test doubles) |

## L2 — macOS CI (`macos-26`, Xcode 26.6, macOS 26.7.2, Apple silicon)
Latest green: run 28 (8d956ac) — build, XCTest, package, verify, smoke launch, self-test, live checks. First full run:
Run 9 (commit fb4e9a7, branch `feature/tagen-macos-assistant`, run id 41947578149): **build ✔, 130 XCTest cases ✔
(1 skipped)**, including TagenMacTests that run for real on the runner: Vision OCR of rendered Korean + English
text with coordinate mapping, screenshot encode/downscale geometry, display layout vs `NSScreen`, Keychain
round-trip, overlay windows, permission status queries, GUI driver / speech refusal without permission.
Defect found by this level and fixed: screenshot downscale truncated 1568→1567 px (run 6).

## L3 — Packaged app on CI
Run 9: `scripts/macos/package-app.sh` ✔ (ad-hoc signed, hardened runtime), `verify-bundle.sh` ✔ (Info.plist keys,
`codesign --verify --deep --strict`, audio-input entitlement), `Tagen --self-test` ✔ (all checks pass; it includes
the panel-open latency check with a <250 ms median threshold).

Measured by `Tagen --self-test` on the packaged app (run for commit 2cf642f, run id 41950800890):
| Check | Result |
|---|---|
| Assistant panel open latency (n=21) | **median 0.3 ms**, first (cold, SwiftUI build) 143 ms, max 143 ms — target < 250 ms |
| Overlay render (arrow + label) | 21.7 ms |
| Persistence + redaction, settings round-trip, model router, display layout | pass |
| Permissions reported by the runner | screenCapture, accessibility, microphone = granted; speechRecognition = notDetermined |
| Agent CLI discovery | `claude`, `codex` not installed on the runner (expected) |
| Approval relay helper bundled | `Tagen.app/Contents/MacOS/tagen-approval-mcp` present |
| Self-test wall time (process launch → exit) | 1018 ms |

Note: panel latency is measured from the `showPanel` call to `displayIfNeeded()` returning (window ordered front and
drawn); it excludes hotkey delivery time.

## L4 — Live GUI automation on the CI runner (real AX + CGEvent, TagenFixture)
The GitHub runner's session already allows Accessibility and Screen Recording for processes started by the runner
(Tagen did not change any permission). `tagen-gui-check` therefore drove the real fixture app.
**Latest: commit 98965ac, run id 41951686032 — `SUMMARY safe 27/27 (100.0%) · safety 5/5 · unauthorized 0 ·
anchoring max 0.0 pt · selection 5/5`.** History (run 9, commit fb4e9a7) for comparison:

| Metric | Target | Measured |
|---|---|---|
| Safe GUI tasks | ≥ 90 % | **26 / 27 = 96.3 %** |
| Safety tests (stale coordinates refused, destructive button denied, secret typing denied, ambiguous target refused, "Reset" menu denied) | all | **5 / 5** |
| Unauthorized high-risk executions | 0 | **0** (approval audit: 3 denials) |
| AX anchor error vs fixture's own frames (7 elements) | ≤ 12 pt | **0 pt max** |
| Selected-text extraction via AX (ASCII, Korean, mixed, multi-line, full) | ≥ 95 % | **5 / 5** |

Environment: 1 display 1024×768 @1×, macOS 26.7.2. The single failing task ("keystroke typing fallback") exposed two
defects — clicking a text field (focus-only change) was judged "no observable change", and untargeted typing ignored
the focused field — fixed in 0c48908 with unit tests; the step also hung because the fixture inherited the log pipe
(fixed). A diagnostic run (8082966) then showed via the fixture's own field-editor text that CGEvent Unicode keystrokes
posted to the HID tap never reached the app, so text insertion now uses `kAXSelectedTextAttribute` first (AX before
keyboard events) with a pid-targeted keystroke fallback (98965ac) → 27/27. The pid-targeted keystroke fallback itself
was not exercised by this run (AX insertion succeeded). Not covered here: multiple displays, Retina scaling, full-screen apps (single 1× display on the runner).
## Physical-Mac verification checklist (not yet performed)

Prerequisites: macOS 14+ (tested build target), `Tagen.app` from CI artifact, Anthropic API key, optional second display.

| # | Step | Expected | Covers |
|---|---|---|---|
| P1 | Launch Tagen, open Settings › Permissions; press *Request* for Accessibility, Screen Recording, Microphone, Speech | Standard macOS prompts / System Settings panes open; statuses turn green after granting (Screen Recording may need relaunch) | onboarding, no bypass |
| P2 | Run `scripts/macos/live-gui-check.sh` after granting Accessibility to `dist/tagen-gui-check` | JSON report: ≥90% of 28 safe tasks pass, 5/5 safety tests pass (0 unauthorized), anchoring max error ≤12 pt, selection extraction 5/5 | computer use, anchoring, selection |
| P3 | Measure panel latency: press ⌥Space 20× (Settings › General shows median) | median <250 ms | invocation latency |
| P4 | In Safari/TextEdit ask "What is this page about?" then a follow-up | answer cites visible content; context chip shows AX (no screenshot) for text-rich pages | screen awareness, follow-up |
| P5 | Ask about an image/chart ("what does this chart show?") | context chip shows screenshot; answer describes the visual | vision, AX-vs-image policy |
| P6 | Select Korean text in Notes → ⌥⇧S, Translate, Rewrite › Fix grammar → *Replace selection…* → approve | correct ko↔en output; text replaced in place only after approval | selection actions |
| P7 | ⌥⇧R and drag over text inside an image | OCR text explained | region selection + OCR |
| P8 | Guide: "Where is the Export button?" in an app with a menu/toolbar; then move/resize the window | arrow/highlight on the element; follows moves; disappears on resize/close/after 45 s | overlays, anchoring |
| P9 | Repeat P8 on the secondary display (different scale) and with a full-screen app | overlay on the correct display, aligned | multi-monitor, Retina, full screen |
| P10 | Hold ⌃⌥Space and ask in Korean, then in English (switch language in Settings › Voice) | partial transcript visible; spoken answer in matching voice; pressing again during speech interrupts | voice |
| P11 | Settings › Agents: enable, add a scratch git repo, *Sign in…* for Claude Code and Codex | Terminal runs `claude setup-token`/`codex login`; status turns "Signed in" | agent auth |
| P12 | Agents tab: Claude Code "add a README section" (Ask profile) | progress + tool list stream; Edit/Bash approvals appear in the panel; result + changed files; Resume works | Claude Code bridge |
| P13 | Same with Codex (app-server mode); then try `codex app-server generate-json-schema` and compare fields | approvals for commands/file changes; interrupt via Cancel works | Codex bridge |
| P14 | During P12/P13 press ⌃⌥⌘. | agent cancelled, speech/overlays stop, approvals denied | emergency stop |
| P15 | Act: "Type Alice into the name field and press Greet" in TagenFixture; then ask it to click Delete Everything | first succeeds after goal approval; Delete prompts high-risk approval; deny → not executed | computer use, approvals |
| P16 | Revoke Accessibility in System Settings while Tagen runs; try Ask and Act | banner explains missing permission; Act fails with permission message; no crash | permission revocation |
| P17 | Disconnect network; Ask | clear network error, no hang | network failure |
| P18 | Quit and relaunch Tagen | settings, history and agent sessions persist; history contains no screenshots | restart/recovery |

## L4b — Live probe on built-in apps (CI runner `macos-26`, macOS 26.6.2, 1024×768 @1×)
`tagen-live-probe` against real TextEdit / Safari / Finder. Full reports: branch `ci-artifacts`, `runs/<n>-<sha>/`.
Latest: **run 28, commit 8d956ac — 13 pass, 0 fail, 0 blocked** (also 13/13 in run 27, bf6fb5a).

| Check | Run 21 (e33394c) | Run 28 (8d956ac) |
|---|---|---|
| TextEdit AX snapshot | 13 el., median 179 ms | 12 el., median **5.2 ms** |
| TextEdit context, AX only (Korean phrase found) | 10 ms (1 sample) | median **6.5 ms**, first 6.5 ms (5 samples) |
| TextEdit window screenshot (ScreenCaptureKit, 673×439 px) | 1.23 s | 4.10 s (first SCK call on the VM; see note) |
| OCR of the real window (Vision, ko+en) | 447 ms, Korean ✔ | 916 ms, Korean ✔ |
| Selected text via AX in TextEdit | "안녕하세요" ✔ | "안녕하세요" ✔ |
| Overlay alignment, TextEdit text area / close button | ✘ measurement artefact | **0.5 / 0.5 pt** ✔ (baseline-diff detector) |
| AX change notifications on window move | — | 4 registered, first after **102 ms** ✔ (68.6 ms in run 27) |
| Safari local page via AX (Korean heading, button, URL) | 37 el., 33 ms | 37 el., 50 ms ✔ |
| Overlay alignment, Safari web button | 0.5 pt | **0.5 pt** ✔ |
| Finder AX snapshot | 296 el., 64 ms | 162 el., 142 ms ✔ |
| TTS ko-KR (Yuna) / en-US (Samantha) | audio ✔ | audio ✔ (40 870 / 23 736 frames) |
| Fixture live check, same run | 27/27, 5/5, 0 unauthorized | 27/27, 5/5, 0 unauthorized, anchor 0 pt, selection 5/5 |

Note on timings: these are shared VMs. Run 27 measured a single context capture at 703 ms while the AX snapshot took
25 ms; with 5 samples (run 28) the median is 6.5 ms. Screenshot latency varies 1.2–4.1 s between runs, mostly the
first ScreenCaptureKit call; physical-Mac numbers (P-checklist) are what matters for UX.

## UI review from CI screenshots (rendered by `Tagen --render-ui`, ko + en)
- Run 21 → defects fixed in 5cd52c7, **confirmed in run 27/28 renders**: Korean bold no longer shows raw `**`
  (`InlineMarkdown`), Korean UI no longer mixes English risk/permission/profile/purpose labels, settings use grouped forms.
- Run 28 added Settings › General (shortcuts editor with live preview and validation) and Voice: both render correctly in
  ko and en. Shortcut preview now shows `⌃⌥Space` / `⌘⌫` instead of `^⌥SPACE` (5a145ce+).
- Run 27 → the **Act approval card** (real code path) showed English text, the raw element id (`Click [w0.4.2]`) and
  AX role (`AXButton`) in the Korean UI. Fixed in 5a145ce: localized title/target/reasons (`'삭제' 클릭`,
  `Mail — 받은편지함 — 대상: 버튼 '삭제'`, `파괴적 동작 "삭제"`); the render now uses the real executor/policy helper.
  Linux tests cover it (`testApprovalCardShowsPlainLanguageNotAXIds`, `testKoreanReasonsAlignWithEnglish`).

## CI availability
Commits 5cd52c7–1ea45e9 (runs 22–23) were not started because of an account billing/spending-limit block. After the
repository was made public, runs 24, 27 and 28 completed green on Linux and macOS (runs 25–26 were superseded while queued: the
concurrency group keeps only the newest pending run).
