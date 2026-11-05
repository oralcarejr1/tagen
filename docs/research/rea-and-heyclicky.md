# REA / HeyClicky investigation

Date: 2026-11-05. Environment: Linux cloud container (Ubuntu 24.04, no macOS, no GUI).

## REA availability (directly verified)
| Check | Result |
|---|---|
| `rea`, `reva`, `ghidra` on PATH | not found |
| PyPI `rea` | exists (v0.1.1) — unrelated package |
| npm `rea` | "a fancy wrapper over connect.router" — unrelated |
| PyPI `reverse-engineering-assistant` (ReVa, Ghidra MCP plugin) | exists (v7.3.1); requires Ghidra + a target binary |

**Constraint (verified):** no HeyClicky macOS binary is available in this environment, and the product
website `www.heyclicky.com` does not resolve under this session's network policy
(`getaddrinfo ENOTFOUND`). REA could therefore not inspect HeyClicky. Per the mission, REA research was not
allowed to block the product; Tagen is an independent implementation built only on public Apple APIs and
documented CLI interfaces. No proprietary code, assets or implementation details were used.

## What is known vs. assumed
| Topic | Status | Notes |
|---|---|---|
| HeyClicky is a macOS AI assistant that can see the screen and guide the user | Unverified assumption (from the mission brief) | Could not load the site. |
| Global hotkey invocation | Reasonable inference | Standard for macOS assistants; Tagen uses Carbon `RegisterEventHotKey` (no Accessibility needed). |
| Floating assistant | Reasonable inference | Tagen: non-activating `NSPanel` that can become key. |
| Context acquisition | Verified technique (Apple docs) | AX (`AXUIElement`), ScreenCaptureKit, Vision OCR. |
| Visual overlays | Verified technique | Transparent click-through `NSPanel` per display, `sharingType = .none`. |
| Voice | Verified technique | `SFSpeechRecognizer` (on-device when supported) + `AVSpeechSynthesizer`. |
| Computer use | Verified technique | AX actions first, `CGEvent` fallback. |
| Agent execution | Verified interfaces | Claude Code headless (`-p --output-format stream-json`), Codex `app-server` / `exec --json`. See `codex-claude-protocols.md`. |

## How to continue the investigation on a Mac (optional)
1. Install Ghidra + ReVa (`pip install reverse-engineering-assistant`) per its README.
2. Only inspect a binary you are licensed to analyze; record *behavioural* observations (hotkeys, permission
   prompts, window levels) rather than code. Do not copy code or assets.
