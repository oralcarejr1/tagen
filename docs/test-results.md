# Test results

Only results that were actually executed are recorded here. Verification levels:
**L1** Linux unit/integration (Docker `swift:6.2-noble`, Swift 6.2.4) · **L2** macOS CI (`macos-26`, Xcode 26.6) ·
**L3** packaged-app smoke on CI · **L4** live GUI automation · **L5** physical Mac (manual).

## L1 — Linux (cloud container), commit 279d0a9 + later
`scripts/linux/test.sh` → **126 tests, 0 failures**. Earlier the suite (122 tests then) was repeated 5× with 0 failures
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
