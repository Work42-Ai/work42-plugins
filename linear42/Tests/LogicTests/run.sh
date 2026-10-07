#!/bin/sh
# Compiles the Foundation-only linear42 widget sources with the logic tests and runs them.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
widgets="$here/../../widgets"
# Widgets carry verbatim copies of the shared files; fail if any copy drifts from linear-issue's.
for f in Linear42Config.swift Linear42Logic.swift; do
  if ! diff -q "$widgets/linear-issue/Sources/$f" "$widgets/linear-my-issues/Sources/$f" >/dev/null; then
    echo "DRIFT: widgets/linear-my-issues/Sources/$f differs from widgets/linear-issue/Sources/$f"
    exit 1
  fi
done
# The brand assets and the icon view are in all four widgets.
for f in Linear42Brand.swift LinearBrandMark.swift; do
  for w in linear-my-issues linear-spec linear-testing; do
    if ! diff -q "$widgets/linear-issue/Sources/$f" "$widgets/$w/Sources/$f" >/dev/null 2>&1; then
      echo "DRIFT: widgets/$w/Sources/$f is missing or differs from widgets/linear-issue/Sources/$f"
      exit 1
    fi
  done
done
echo "shared sources: linear-my-issues copies match linear-issue"
out="$(mktemp -d)/linear42-logic-tests"
swiftc -o "$out" "$here/main.swift" "$widgets/linear-issue/Sources/Linear42Config.swift" "$widgets/linear-issue/Sources/Linear42Logic.swift" "$widgets/linear-issue/Sources/Linear42Brand.swift" 2>&1 | grep -v '^$' || true
"$out"
