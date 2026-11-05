# Tagen — repository guide for Claude

Native macOS AI assistant (menu bar + floating panel) with screen awareness, selection actions,
visual guidance overlays, push-to-talk voice, Codex / Claude Code bridge, and safe computer use.

**Resuming work? Read `docs/continuation.md` first**, then `docs/progress.md`.

## Layout
- `Sources/TagenCore` — platform-independent logic (builds/tests on Linux): geometry, context packaging,
  model clients (Anthropic Messages API raw HTTP, OpenAI-compatible), orchestrator, guide parsing,
  annotation lifecycle, computer-use executor + policy, voice state machine, SQLite store, security.
- `Sources/TagenAgents` — Codex (`app-server` JSON-RPC, `exec --json`) and Claude Code (`-p --output-format stream-json`)
  adapters, approval relay (Unix socket + `tagen-approval-mcp`), task manager. Platform-independent.
- `Sources/TagenMac` — macOS implementations (AX, ScreenCaptureKit, Vision, overlays, Speech, CGEvent, Keychain, hotkeys).
  Every file is wrapped in `#if os(macOS)`.
- `Sources/Tagen` — the app (SwiftUI + AppKit). `Tagen --self-test` prints a JSON health report.
- `Sources/TagenFixtureApp`, `Sources/tagen-gui-check` — live GUI verification fixture + driver.
- `Sources/tagen-cli` — headless CLI (agent tasks, auth status, policy checks).

## Commands
- Linux (cloud): `docker build -t tagen-linux scripts/linux` (once; behind a TLS proxy copy the CA to the context as `extra.crt`),
  then `scripts/linux/test.sh`.
- macOS: `swift build --build-tests && swift test`; package: `scripts/macos/package-app.sh` → `dist/Tagen.zip`.
- CI: `.github/workflows/ci.yml` (Linux container job + `macos-26` job: build, test, package, self-test, live GUI check).

## Rules
- Never commit credentials. Secrets live in the Keychain; logs/history are redacted (`Redactor`).
- Never bypass macOS permission prompts or modify TCC (also not in CI).
- Keep conversation history append-only for Claude requests (see `ChatMessage.providerContent`).
- Do not launch the real `claude`/`codex` CLIs in tests; use the fake CLIs in `Tests/TagenAgentsTests/Fixtures`.
- Keep verification levels separate in docs: unit (Linux/macOS), CI compile, automated integration, live macOS GUI.
