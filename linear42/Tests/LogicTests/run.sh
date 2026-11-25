#!/bin/sh
# Compiles the Foundation-only linear42 extension sources with the logic tests and runs them.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../extension/Sources"
# The widgets run in the plugin's extension: one copy of each shared file lives in extension/Sources.
for f in Linear42Config Linear42Logic Linear42Brand Linear42Links LinearBrandMark LinearDocRef RealHome; do
  [ -f "$src/$f.swift" ] || { echo "MISSING: extension/Sources/$f.swift"; exit 1; }
done
if grep -rq '@_cdecl' "$src"; then echo "LOADER: extension/Sources must not export dlopen loader symbols"; exit 1; fi
if grep -rq --exclude=RealHome.swift 'homeDirectoryForCurrentUser' "$src"; then echo "HOME: use RealHome.url (an extension's own home is its sandbox container)"; exit 1; fi
if [ -d "$here/../../widgets/linear-issue/Sources" ]; then echo "STALE: widgets/*/Sources copies must be gone"; exit 1; fi
echo "shared sources: one copy of each in extension/Sources"
# The user-facing widget names (the + Widget menu, the tabs, the "Open in ..." link picker). The browser surface's chrome label
# must match the widget's own title.
check_title() {
  file="$src/$1.swift"
  if ! grep -q "^    let title = \"$2\"\$" "$file"; then echo "TITLE: $1 should have title \"$2\""; exit 1; fi
  if [ "$3" = "surface" ] && ! grep -q "title: \"$2\"," "$file"; then echo "TITLE: $1 browser surface label should also be \"$2\""; exit 1; fi
}
check_title LinearIssueWidget "Issue Details" surface
check_title LinearSpecWidget "Spec Document" surface
check_title LinearTestingWidget "Testing Plan Document" surface
check_title LinearQAWidget "QA Report Document" surface
check_title LinearMyIssuesWidget "My Linear Issues"
echo "widget titles: Issue Details / Spec Document / Testing Plan Document / QA Report Document / My Linear Issues"
out="$(mktemp -d)/linear42-logic-tests"
swiftc -o "$out" "$here/main.swift" "$src/Linear42Config.swift" "$src/Linear42Logic.swift" "$src/Linear42Brand.swift" "$src/Linear42Links.swift" "$src/RealHome.swift" 2>&1 | grep -v '^$' || true
"$out"
