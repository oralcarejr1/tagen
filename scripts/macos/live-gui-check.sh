#!/usr/bin/env bash
# Live GUI verification: launches the fixture app and drives it through Tagen's real
# computer-use stack (AXUIElement + CGEvent). It never modifies permissions; if the
# Accessibility permission is not granted (e.g. on a CI runner), it reports BLOCKED
# rather than simulating success.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
mkdir -p test-results
"$ROOT/dist/tagen-gui-check" --fixture "$ROOT/dist/TagenFixture.app" --output test-results/live-gui-check.json
STATUS=$?
exit $STATUS
