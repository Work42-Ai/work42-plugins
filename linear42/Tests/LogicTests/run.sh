#!/bin/sh
# Compiles the Foundation-only linear42 widget sources with the logic tests and runs them.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
widgets="$here/../../widgets"
out="$(mktemp -d)/linear42-logic-tests"
swiftc -o "$out" "$here/main.swift" "$widgets/linear-issue/Sources/Linear42Config.swift" "$widgets/linear-issue/Sources/Linear42Logic.swift" 2>&1 | grep -v '^$' || true
"$out"
