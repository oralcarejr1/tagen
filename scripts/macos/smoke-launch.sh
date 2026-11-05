#!/usr/bin/env bash
# Launches the app binary with --self-test: initializes subsystems (store, settings, model
# router, agent discovery, permission checks, display layout) and exits with a JSON report.
set -euo pipefail
APP="${1:-dist/Tagen.app}"
mkdir -p test-results
START=$(python3 -c 'import time; print(time.time())')
"$APP/Contents/MacOS/Tagen" --self-test > test-results/self-test.json
END=$(python3 -c 'import time; print(time.time())')
cat test-results/self-test.json
python3 - "$START" "$END" <<'PY'
import json, sys
start, end = float(sys.argv[1]), float(sys.argv[2])
r = json.load(open("test-results/self-test.json"))
print(f"self-test wall time: {(end-start)*1000:.0f} ms")
failed = [c for c in r.get("checks", []) if c.get("status") == "fail"]
if failed:
    print("FAILED checks:", failed); sys.exit(1)
print("PASS: self-test")
PY
