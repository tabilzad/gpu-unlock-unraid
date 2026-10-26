#!/bin/bash
# Run every test script; exit 1 if any fails.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rc=0
for t in "$here"/test-*.sh; do
  echo "=== $(basename "$t")"
  bash "$t" || rc=1
  echo
done
[ "$rc" -eq 0 ] && echo "tests: ok" || echo "tests: FAILED" >&2
exit "$rc"
