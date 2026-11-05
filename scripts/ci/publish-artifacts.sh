#!/usr/bin/env bash
# Publishes CI reports and UI screenshots to the `ci-artifacts` branch under runs/<run>-<sha>/ so they can be
# reviewed with plain git (artifact downloads may be blocked in some environments). Append-only; never force-pushes.
# Requires GITHUB_TOKEN (contents: write) and GITHUB_REPOSITORY; the token is never printed.
set -euo pipefail
: "${GITHUB_TOKEN:?GITHUB_TOKEN required}" "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
RUN_DIR="runs/${GITHUB_RUN_NUMBER:-local}-${GITHUB_SHA:0:7}"
SRC="$(pwd)/test-results"
WORK="$(mktemp -d)"
REMOTE="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
cd "$WORK"
git init --quiet .
git config user.name "tagen-ci"
git config user.email "tagen-ci@users.noreply.github.com"
git remote add origin "$REMOTE"
if git fetch --quiet --depth 1 origin ci-artifacts 2>/dev/null; then
  git checkout --quiet -b ci-artifacts FETCH_HEAD
else
  git checkout --quiet --orphan ci-artifacts
  printf '# Tagen CI artifacts\nReports and UI screenshots published by CI (runs/<run>-<sha>/). Not source code.\n' > README.md
fi
mkdir -p "$RUN_DIR"
[ -d "$SRC/ui" ] && cp -R "$SRC/ui" "$RUN_DIR/"
for f in self-test.json live-gui-check.json live-probe.json live-probe.log render-ui.log smoke-launch.log; do
  if [ -f "$SRC/$f" ]; then cp "$SRC/$f" "$RUN_DIR/"; fi
done
git add -A
git commit --quiet -m "CI artifacts for run ${GITHUB_RUN_NUMBER:-local} (${GITHUB_SHA:0:7})" || { echo "nothing to publish"; exit 0; }
for i in 1 2 3; do
  if git push --quiet origin ci-artifacts 2>/dev/null; then echo "published to ci-artifacts/$RUN_DIR"; exit 0; fi
  sleep $((i * 3)); git pull --quiet --rebase origin ci-artifacts 2>/dev/null || true
done
echo "publish failed"; exit 1
