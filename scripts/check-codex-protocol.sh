#!/usr/bin/env bash
# Regenerates Codex app-server TypeScript bindings for a given codex version and diffs the
# subset Tagen depends on (docs/research/codex-app-server-<ver>/) — run after upgrading Codex.
# Usage: scripts/check-codex-protocol.sh [codex-version]   (requires npm; no Codex login needed)
set -euo pipefail
VER="${1:-latest}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="$(ls -d "$ROOT"/docs/research/codex-app-server-* | sort -V | tail -1)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && npm init -y >/dev/null && npm install --no-audit --no-fund "@openai/codex@$VER" >/dev/null)
"$TMP/node_modules/.bin/codex" --version
"$TMP/node_modules/.bin/codex" app-server generate-ts --out "$TMP/ts" >/dev/null
status=0
for f in "$REF"/*.ts; do
  name="$(basename "$f")"
  new="$(ls "$TMP/ts/$name" "$TMP/ts/v2/$name" 2>/dev/null | head -1 || true)"
  if [ -z "$new" ]; then echo "MISSING: $name"; status=1; continue; fi
  if ! diff -q <(grep -v '^//' "$f") <(grep -v '^//' "$new") >/dev/null; then echo "CHANGED: $name"; status=1; fi
done
[ $status -eq 0 ] && echo "OK: protocol subset unchanged vs $(basename "$REF")" || echo "Review CodexAppServerAdapter for the files above."
exit $status
