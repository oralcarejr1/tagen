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

- GitHub Actions is currently blocked by account billing (spending limit); the latest UI commits are compiled on Linux
  only. macOS runner minutes are expensive — consider running CI on demand (`workflow_dispatch`) once billing is fixed.

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
