# Continuation notes (read first when resuming)

1. **Objective** — Tagen: native macOS AI assistant (screen awareness, selection actions, overlays, voice,
   Codex/Claude Code bridge, safe computer use). See `CLAUDE.md`, `docs/architecture.md`.
2. **Current phase** — Phase 6 (integration, packaging, verification, docs). All phases implemented.
3. **Completed** — all modules, app UI, fixture + live checker, CI (Linux + macOS 26), packaging, docs.
4. **Pending** — physical-Mac checklist (P1–P18 in test-results); real Codex/Claude Code runs with login on the Mac;
   Developer ID signing + notarization (needs the user's certificate).
5. **Exact next action** — run the physical-Mac checklist. CI is green and publishes reports + UI screenshots to the
   `ci-artifacts` branch (`runs/<n>-<sha>/`); after each change review `ui/*.png` and `live-probe.log` there.
6. **Latest test results** — Linux 151 tests ✔. macOS CI run 28 (8d956ac): build/tests/package/self-test ✔, live GUI
   27/27 safe, 5/5 safety, 0 unauthorized, anchor 0 pt, selection 5/5; live probe 13/13 (TextEdit/Safari/Finder/TTS,
   overlay alignment 0.5 pt, AX notifications ✔). Details: `docs/test-results.md`.
7. **Commands** — `scripts/linux/test.sh` (Docker image `tagen-linux` from `scripts/linux/Dockerfile`);
   macOS: `swift test`, `scripts/macos/package-app.sh`, `scripts/macos/live-gui-check.sh`.
8. **External blockers** — no Mac/GUI/microphone in the cloud session; CI runners have no microphone/speech
   permission; `www.heyclicky.com` not reachable from the session; real Codex/Claude CLIs intentionally not run here;
   notarization needs a Developer ID.
