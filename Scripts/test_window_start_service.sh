#!/bin/bash
set -euo pipefail

TASK_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexmeter-window-test.XXXXXX")"
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT

# Compile the actual App Server dispatcher; replace only unrelated app services.
xcrun swiftc -parse-as-library -module-cache-path "$TASK_BUILD_DIR/module-cache" \
  "$TASK_PROJECT_DIR"/CodexMeter/Core/*.swift \
  "$TASK_PROJECT_DIR/CodexMeter/CodexUsageService.swift" \
  "$TASK_PROJECT_DIR/Tests/WindowStartServiceIntegration/main.swift" \
  -lsqlite3 -o "$TASK_BUILD_DIR/integration"
"$TASK_BUILD_DIR/integration" "$TASK_PROJECT_DIR/Tests/WindowStartServiceIntegration/fake_codex.py"
