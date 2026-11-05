# Known limitations

## Environment / verification
- Developed in a Linux cloud container without macOS, Xcode, a GUI, microphone, or the user's Mac. macOS code is
  compiled and unit-tested on GitHub `macos-26` runners. CI runners do not grant Accessibility, Screen Recording,
  Microphone or Speech permissions, so live AX automation, capture, overlays-over-real-apps and voice have **not** been
  exercised against third-party apps. (GitHub's `macos-26` runner session happens to allow Accessibility/Screen
  Recording for runner-launched processes, so the fixture-app live check *did* run there — see test-results. Tagen never
  edits TCC; elsewhere `tagen-gui-check` reports `blocked` instead of simulating.)
- REA could not inspect HeyClicky: no binary available and `www.heyclicky.com` is blocked by the session network policy.
- Codex: verified against the official app-server schema and the real `codex app-server` 0.166.0 binary (handshake,
  thread/turn start, interrupt, resume) — but no model turn completed (no login/network), so live approvals and tool
  events from a real model run remain unverified. Re-check after upgrades with `scripts/check-codex-protocol.sh`.
- Claude Code: formats checked against the Agent SDK 0.3.318 type definitions; the real `claude` CLI was intentionally
  never launched from this development session, so an end-to-end run happens first on your Mac.

- CI runs on every push to `feature/**`/`claude/**`/`main`. The repository is public, so GitHub-hosted runner minutes
  are free; if it is made private again, macOS minutes count 10× against the plan — switch to `workflow_dispatch`.

## Product
- Development build is **ad-hoc signed, hardened runtime, not notarized**. Gatekeeper will block a downloaded copy until
  you remove the quarantine attribute or right-click → Open. TCC grants are tied to the code signature, so each new
  build may require re-granting permissions. Distribution would need a Developer ID certificate + notarization.
- Not sandboxed (Accessibility-based assistants cannot work inside the App Sandbox).
- Selected-text extraction relies on `kAXSelectedTextAttribute`; apps that don't expose it (some Electron/canvas apps,
  terminals, some browsers' web content) return no selection → use region selection (OCR) instead. The clipboard is
  never read or written automatically (only on explicit "Copy").
- Replacement of selected text works only where the focused element accepts `kAXSelectedTextAttribute` writes.
- Element-anchored annotations update on AX notifications (moved/resized/destroyed, measured 68–102 ms to first
  notification on CI) with a 0.5 s poll as fallback for apps that do not post them; very fast animations may lag. Screenshot-box annotations are dropped when their window resizes (coordinates stale).
- Claude subscription provider (`claude` CLI): each request starts a CLI process, so replies begin about 6–7 s
  after sending on an M5 Pro (measured with Sonnet) instead of about 1–2 s with the API; requests count toward the
  subscription's usage limits (a limit message maps to "rate limited"); no prompt caching across turns (each turn
  resends the flattened conversation); `maxTokens` is not passed (the CLI has no flag for it). Depends on CLI flags
  checked against Claude Code 2.1.318.
- ChatGPT subscription provider (`codex` CLI): no text streaming (the answer appears when the turn ends); 7–20 s per
  request measured; each request carries about 14k input tokens of Codex's own agent instructions (counts toward the
  subscription limits); a few inert agent tools stay visible because Codex cannot run as a bare model; `--ignore-user-config`
  means the model in `~/.codex/config.toml` is not used unless entered in Settings › Models. In one probe
  `gpt-6.1-sol` misread a tiny 64×32 test image that the default model read correctly; on a real UI screenshot the
  default model was correct. Depends on CLI flags checked against codex-cli 0.166.0.
- Signing: with `scripts/macos/setup-dev-signing.sh` builds use a self-signed local certificate (stable designated
  requirement, so permissions survive rebuilds). It is not trusted by Gatekeeper and is not a Developer ID; builds from
  CI stay ad-hoc. Permissions granted to earlier ad-hoc builds do not carry over: grant them once more for the first
  certificate-signed build (remove stale "Tagen" rows in System Settings if a switch shows on but has no effect).
- Synthetic keystrokes (CGEvent) do not trigger macOS input-source shortcuts, so the ⌃⌥Space fix was verified by the
  self-test (no default conflicts with the Mac's enabled shortcuts) and needs a physical key press to confirm.
- Guide/Act quality depends on the model; all model output is validated, but the planner can still choose wrong
  (valid) actions — risky ones always require approval.
- Live CI showed CGEvent Unicode keystrokes posted to the HID event tap did not reach the fixture app; Tagen therefore
  inserts text via AX (`AXValue` / `AXSelectedText`). The remaining keystroke fallback (secure fields, apps without AX
  text support) now posts to the target pid but has not been verified live.
- `secondsSinceUserInput` uses HID idle time and excludes Tagen's own events heuristically (timing-based).
- Push-to-talk hotkey uses Carbon hotkeys (press/release); if another app owns the same combination registration fails
  and the panel shows a warning. Shortcuts are configurable in Settings › General as text (`opt+shift+s`); there is
  no "press the keys" recorder yet.
- Agent subprocesses are signalled directly (SIGINT→SIGTERM→SIGKILL); grandchildren rely on the CLI's own cleanup.
- "Continue this conversation" (History) starts a fresh model context that includes the earlier transcript as
  untrusted text; screenshots are not stored, so the original turns are not replayed (append-only history is kept).
- Act approval cards are localized (ko/en) and name the target in plain language (`버튼 '삭제'`); approval text for
  Codex/Claude Code tool calls comes from the agent and is shown as-is (English).
- Local speech: on-device recognition is used when `supportsOnDeviceRecognition` is true for the chosen language;
  otherwise Apple's server recognition is used (system behaviour).
- Single-user design: no accounts, sync, telemetry or multi-tenant features.
