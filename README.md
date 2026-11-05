# Tagen

A native macOS AI assistant for one power user: it understands what is on your screen, explains and rewrites
selected text, points at UI elements with on-screen overlays, talks with push-to-talk voice, delegates coding tasks to
**Codex** and **Claude Code**, and can operate apps safely with approval for risky steps.

> Development build: ad-hoc signed and **not notarized**. See [docs/known-limitations.md](docs/known-limitations.md).

## Features
| Area | What it does |
|---|---|
| Screen awareness | Reads the active app/window via Accessibility; captures window/region with ScreenCaptureKit only when needed; Vision OCR (ko/en); answers with conversational follow-up. |
| Selection actions | Explain / Summarize / Translate (ko↔en) / Rewrite / Custom on AX-selected text or a drawn region; approved in-place replacement. No clipboard monitoring. |
| Visual guidance | Arrows, circles, highlights and labels in click-through overlays on every display; anchored to AX elements and removed when targets change. |
| Voice | Push-to-talk (hold ⌥⇧Space or the mic button), partial transcripts, ko-KR/en-US, on-device when available, spoken answers, interrupt/cancel, text fallback. |
| Models | Anthropic API, OpenAI-compatible/local endpoints, or a Claude / ChatGPT subscription via the Claude Code / Codex CLI (no API key). |
| Coding agents | Claude Code (`claude -p --output-format stream-json`, approvals via bundled MCP relay) and Codex (`codex app-server`, or `codex exec --json`); progress, tool activity, approvals, cancel, resume, crash recovery. |
| Computer use | Typed actions (click, type, menu, keys, scroll, wait, focus) with Observe → Identify → Validate → Authorize → Execute → Re-observe → Verify. |
| Safety | Per-capability permissions, risk policy, approvals, global emergency stop (⌃⌥⌘.), Keychain secrets, redaction, no stored screenshots/audio. |

## Install a development build
1. Download `Tagen-dev-build` from the latest successful CI run (Actions → CI → artifacts) and unzip `Tagen.zip`.
2. Move `Tagen.app` to `/Applications`, then remove the download quarantine (unsigned dev build):
   ```bash
   xattr -dr com.apple.quarantine /Applications/Tagen.app
   ```
3. Open Tagen (menu-bar sparkle icon). Settings › Permissions walks through each permission.
4. Settings › Models: paste an Anthropic API key (stored in the Keychain), **or** press "Use my Claude subscription for all
   tasks" / "Use my ChatGPT subscription for all tasks" to run through the Claude Code / Codex CLI signed in on this
   Mac (no API key or credits). Optional: OpenAI-compatible/local endpoint.
5. Settings › Agents: enable agent execution, sign in to each CLI on this Mac (opens Terminal) or paste a token.

## Build from source (macOS 14+, Xcode 26 / Swift 6.2)
```bash
swift build --build-tests
```
```bash
swift test
```
```bash
scripts/macos/setup-dev-signing.sh
```
```bash
scripts/macos/package-app.sh
```
`setup-dev-signing.sh` (once per Mac) creates a local signing certificate in its own keychain file, so every build has
the same identity and macOS permissions survive rebuilds. Without it builds are ad-hoc signed and lose them each time.
Full Xcode is required (Command Line Tools lack XCTest and the SwiftUI macros); if `xcode-select` points elsewhere,
prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
The last command produces `dist/Tagen.app`, `dist/Tagen.zip`, `dist/TagenFixture.app` and `dist/tagen-gui-check`.

Live GUI verification (grant Accessibility to `dist/tagen-gui-check` first):
```bash
scripts/macos/live-gui-check.sh
```

## Platform-independent development (Linux / cloud)
```bash
docker build -t tagen-linux scripts/linux
```
```bash
scripts/linux/test.sh
```

## Shortcuts
⌥Space assistant · ⌥⇧Space (hold) talk · ⌥⇧S explain selection · ⌥⇧G guide · ⌥⇧R region · ⌃⌥⌘. emergency stop

Tagen never registers a shortcut that is an enabled macOS shortcut (e.g. ⌃Space / ⌃⌥Space for switching input
sources): such bindings are moved to the action's default or left unbound, with a notice.

## Documentation
[Architecture](docs/architecture.md) · [Progress](docs/progress.md) · [Test results](docs/test-results.md) ·
[Known limitations](docs/known-limitations.md) · [Research](docs/research/) · [Continuation](docs/continuation.md)
