# Continuation notes (read first when resuming)

1. **Objective** — Tagen: native macOS AI assistant (screen awareness, selection actions, overlays, voice,
   Codex/Claude Code bridge, safe computer use). See `CLAUDE.md`, `docs/architecture.md`.
2. **Current phase** — Phase 6 (integration, packaging, verification, docs). All phases implemented.
3. **Completed** — all modules, app UI, fixture + live checker, CI (Linux + macOS 26), packaging, docs.
4. **Pending** — keep macOS CI green through package/smoke steps; record results in `docs/test-results.md`;
   physical-Mac checklist (P1–P18 in test-results) cannot be done from the cloud.
5. **Exact next action** — restore GitHub Actions billing/spending limit, then re-run CI on `feature/tagen-macos-assistant` (verifies UI fixes + probe overlay diff on macOS; review `ci-artifacts/runs/<n>-<sha>/ui/*.png`). After that: run the physical-Mac checklist (P1–P18). Previously: inspect the latest CI run on `feature/tagen-macos-assistant`
   (GitHub Actions → CI); if green, download artifacts and update `docs/test-results.md`.
6. **Latest test results** — CI run 41951686032 (98965ac): Linux ✔, macOS build/130 tests/package/self-test ✔, live GUI 27/27 safe, 5/5 safety, 0 unauthorized, anchor 0 pt, selection 5/5. Earlier: Linux: 126 tests pass (5/5 repeated runs earlier at 122). macOS CI run 6: 130 tests,
   1 failure (rounding bug, fixed in 279d0a9).
7. **Commands** — `scripts/linux/test.sh` (Docker image `tagen-linux` from `scripts/linux/Dockerfile`);
   macOS: `swift test`, `scripts/macos/package-app.sh`, `scripts/macos/live-gui-check.sh`.
8. **External blockers** — GitHub Actions jobs blocked by account billing/spending limit (since commit 5cd52c7); no Mac/GUI/microphone in cloud; CI runners lack TCC permissions (live GUI check reports
   `blocked`); `www.heyclicky.com` not reachable from the session; real Codex/Claude CLIs intentionally not run.
