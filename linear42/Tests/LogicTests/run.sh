#!/bin/sh
# Compiles the Foundation-only linear42 widget sources with the logic tests and runs them.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
widgets="$here/../../widgets"
# The my-issues widget carries verbatim copies of the shared files; fail if they drift.
for f in Linear42Config.swift Linear42Logic.swift; do
  if ! diff -q "$widgets/linear-issue/Sources/$f" "$widgets/linear-my-issues/Sources/$f" >/dev/null; then
    echo "DRIFT: widgets/linear-my-issues/Sources/$f differs from widgets/linear-issue/Sources/$f"
    exit 1
  fi
done
echo "shared sources: linear-my-issues copies match linear-issue"
out="$(mktemp -d)/linear42-logic-tests"
swiftc -o "$out" "$here/main.swift" "$widgets/linear-issue/Sources/Linear42Config.swift" "$widgets/linear-issue/Sources/Linear42Logic.swift" 2>&1 | grep -v '^$' || true
"$out"
