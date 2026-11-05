# Known limitations

## Environment / verification
- Developed in a Linux cloud container without macOS, Xcode, a GUI, microphone, or the user's Mac. macOS code is
  compiled and unit-tested on GitHub `macos-26` runners. CI runners do not grant Accessibility, Screen Recording,
  Microphone or Speech permissions, so live AX automation, capture, overlays-over-real-apps and voice have **not** been
  exercised against third-party apps. (GitHub's `macos-26` runner session happens to allow Accessibility/Screen
  Recording for runner-launched processes, so the fixture-app live check *did* run there — see test-results. Tagen never
  edits TCC; elsewhere `tagen-gui-check` reports `blocked` instead of simulating.)
- REA could not inspect HeyClicky: no binary available and `www.heyclicky.com` is blocked by the session network policy.
- Real `claude` / `codex` CLIs were never executed (by design, to avoid recursive Claude Code launches); protocol
  behaviour is verified against deterministic fakes. Exact field names must be confirmed on the Mac:
  - Codex app-server: run `codex app-server generate-json-schema` and compare with `CodexAppServerAdapter`.
  - Claude Code `--permission-prompt-tool` MCP reply contract (`behavior/updatedInput/message`) was not confirmed in
    the fetched docs; if it differs, prompts are denied and listed in `permission_denials`.

## Product
- Development build is **ad-hoc signed, hardened runtime, not notarized**. Gatekeeper will block a downloaded copy until
  you remove the quarantine attribute or right-click → Open. TCC grants are tied to the code signature, so each new
  build may require re-granting permissions. Distribution would need a Developer ID certificate + notarization.
- Not sandboxed (Accessibility-based assistants cannot work inside the App Sandbox).
- Selected-text extraction relies on `kAXSelectedTextAttribute`; apps that don't expose it (some Electron/canvas apps,
  terminals, some browsers' web content) return no selection → use region selection (OCR) instead. The clipboard is
  never read or written automatically (only on explicit "Copy").
- Replacement of selected text works only where the focused element accepts `kAXSelectedTextAttribute` writes.
- Element-anchored annotations follow targets by polling AX frames (~8 Hz), not by AX notifications; very fast
  animations may lag one frame. Screenshot-box annotations are dropped when their window resizes (coordinates stale).
- Guide/Act quality depends on the model; all model output is validated, but the planner can still choose wrong
  (valid) actions — risky ones always require approval.
- Live CI showed CGEvent Unicode keystrokes posted to the HID event tap did not reach the fixture app; Tagen therefore
  inserts text via AX (`AXValue` / `AXSelectedText`). The remaining keystroke fallback (secure fields, apps without AX
  text support) now posts to the target pid but has not been verified live.
- `secondsSinceUserInput` uses HID idle time and excludes Tagen's own events heuristically (timing-based).
- Push-to-talk hotkey uses Carbon hotkeys (press/release); if another app owns the same combination registration fails
  and the panel shows a warning. Hotkeys are not yet user-configurable (defaults in Settings › General).
- Agent subprocesses are signalled directly (SIGINT→SIGTERM→SIGKILL); grandchildren rely on the CLI's own cleanup.
- Resuming a conversation from History shows the transcript but starts a fresh model context (images are not stored,
  so replaying the original turns would violate append-only history).
- Local speech: on-device recognition is used when `supportsOnDeviceRecognition` is true for the chosen language;
  otherwise Apple's server recognition is used (system behaviour).
- Single-user design: no accounts, sync, telemetry or multi-tenant features.
