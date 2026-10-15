#!/bin/sh
# Compiles the shared Firebase sources (Foundation/SwiftUI/Observation only) with the logic tests and runs them.
# Every test uses a temporary directory; the real ~/.work42/firebase/config.json is never touched.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
shared="$here/../../shared"
out="$(mktemp -d)/firebase-logic-tests"
swiftc -parse-as-library -o "$out" "$here/main.swift" "$shared/FirebaseProjectConfig.swift" "$shared/FirebaseProjectPicker.swift" 2>&1 | grep -v '^$' || true
"$out"
