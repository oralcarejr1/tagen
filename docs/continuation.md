# Continuation notes (read first when resuming)

1. **Objective** — Tagen: native macOS AI assistant (screen awareness, selection actions, overlays, voice,
   Codex/Claude Code bridge, safe computer use). See `CLAUDE.md`, `docs/architecture.md`.
2. **Current phase** — Phase 6 (integration, packaging, verification, docs). All phases implemented.
3. **Completed** — all modules, app UI, fixture + live checker, CI (Linux + macOS 26), packaging, docs.
4. **Pending** — keep macOS CI green through package/smoke steps; record results in `docs/test-results.md`;
   physical-Mac checklist (P1–P18 in test-results) cannot be done from the cloud.
5. **Exact next action** — inspect the latest CI run on `claude/youthful-wright-2y3ulz`
   (GitHub Actions → CI); if green, download artifacts and update `docs/test-results.md`.
6. **Latest test results** — Linux: 126 tests pass (5/5 repeated runs earlier at 122). macOS CI run 6: 130 tests,
   1 failure (rounding bug, fixed in 279d0a9).
7. **Commands** — `scripts/linux/test.sh` (Docker image `tagen-linux` from `scripts/linux/Dockerfile`);
   macOS: `swift test`, `scripts/macos/package-app.sh`, `scripts/macos/live-gui-check.sh`.
8. **External blockers** — no Mac/GUI/microphone in cloud; CI runners lack TCC permissions (live GUI check reports
   `blocked`); `www.heyclicky.com` not reachable from the session; real Codex/Claude CLIs intentionally not run.
