#!/usr/bin/env bash
# Build and test the platform-independent modules inside the tagen-linux Docker image.
# Usage: scripts/linux/test.sh [extra swift test args]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${TAGEN_LINUX_IMAGE:-tagen-linux}"
docker run --rm -v "$ROOT":/src -v tagen-linux-build:/src/.build -w /src "$IMAGE" \
  bash -lc "swift build --build-tests 2>&1 && swift test --skip-build $* 2>&1"
