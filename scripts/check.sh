#!/bin/zsh
# Run before every commit: all unit tests, then a full app build.
set -euo pipefail
cd "${0:A:h}/.."

echo "▸ Unit tests"
# One run decides (2026-11-17): it used to run twice and only the second counted, so a test that failed once passed.
log=$(mktemp -t brim-tests)
if swift test --package-path Packages/BrimKit >"$log" 2>&1; then tests_ok=1; else tests_ok=0; fi
grep -E "✔ Test run|✘|error:" "$log" || true
if [[ $tests_ok == 0 ]] || grep -q "✘" "$log"; then
  echo "✘ Tests failed: nothing is ready. Full output: $log"
  exit 1
fi

echo "▸ App build"
scripts/build.sh

echo "✓ All checks passed"
