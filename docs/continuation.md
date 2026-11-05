# Continuation notes

1. **Objective** — build Tagen, a native macOS AI assistant (see CLAUDE.md), Phases 0–6.
2. **Current phase** — Phase 0–6 code written; first macOS CI run pending. Tests being written.
3. **Completed** — TagenCore, TagenAgents, TagenMac, app, fixture, gui-check, CI workflow, packaging scripts.
4. **Pending** — unit/integration tests; macOS CI compile fixes; docs (architecture, progress, test-results, limitations, research).
5. **Exact next action** — check latest CI run on branch `claude/youthful-wright-2y3ulz`; fix macOS compile errors.
6. **Latest test results** — Linux: full package builds (Swift 6.2.4). No tests yet.
7. **Commands** — `scripts/linux/test.sh`; CI via push.
8. **External blockers** — no macOS/Xcode in the cloud container; live GUI/voice/permission tests need a physical Mac.
