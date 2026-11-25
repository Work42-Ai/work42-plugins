#!/bin/sh
# Compiles the extension's Firebase sources (Foundation/SwiftUI/Observation only) with the logic tests and runs them.
# Every test uses a temporary directory; the real ~/.work42/firebase/config.json is never touched.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../extension/Sources"
out="$(mktemp -d)/firebase-logic-tests"
swiftc -parse-as-library -o "$out" "$here/main.swift" "$src/FirebaseProjectConfig.swift" "$src/FirebaseProjectPicker.swift" "$src/FirebaseProduct.swift" "$src/FirebaseBrand.swift" "$src/FirebaseTabs.swift" "$src/RealHome.swift" 2>&1 | grep -v '^$' || true
"$out"
