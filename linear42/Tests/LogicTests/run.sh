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
# The brand assets and the icon view are in all five widgets.
for f in Linear42Brand.swift LinearBrandMark.swift; do
  for w in linear-my-issues linear-spec linear-testing linear-qa; do
    if ! diff -q "$widgets/linear-issue/Sources/$f" "$widgets/$w/Sources/$f" >/dev/null 2>&1; then
      echo "DRIFT: widgets/$w/Sources/$f is missing or differs from widgets/linear-issue/Sources/$f"
      exit 1
    fi
  done
done
# The link patterns are in the four widgets that claim links.
for w in linear-spec linear-testing linear-qa; do
  if ! diff -q "$widgets/linear-issue/Sources/Linear42Links.swift" "$widgets/$w/Sources/Linear42Links.swift" >/dev/null 2>&1; then
    echo "DRIFT: widgets/$w/Sources/Linear42Links.swift is missing or differs from widgets/linear-issue/Sources/Linear42Links.swift"
    exit 1
  fi
done
echo "shared sources: linear-my-issues copies match linear-issue"
# The user-facing widget names (the + Widget menu, the tabs, the "Open in ..." link picker). The browser
# surface's chrome label must match the widget's own title.
check_title() {
  file="$widgets/$1/Sources/Widget.swift"
  if ! grep -q "^    let title = \"$2\"\$" "$file"; then echo "TITLE: widgets/$1 should have title \"$2\""; exit 1; fi
  if [ "$3" = "surface" ] && ! grep -q "title: \"$2\"," "$file"; then echo "TITLE: widgets/$1 browser surface label should also be \"$2\""; exit 1; fi
}
check_title linear-issue "Issue Details" surface
check_title linear-spec "Spec Document" surface
check_title linear-testing "Testing Plan Document" surface
check_title linear-qa "QA Report Document" surface
check_title linear-my-issues "My Linear Issues"
echo "widget titles: Issue Details / Spec Document / Testing Plan Document / QA Report Document / My Linear Issues"
out="$(mktemp -d)/linear42-logic-tests"
swiftc -o "$out" "$here/main.swift" "$widgets/linear-issue/Sources/Linear42Config.swift" "$widgets/linear-issue/Sources/Linear42Logic.swift" "$widgets/linear-issue/Sources/Linear42Brand.swift" "$widgets/linear-issue/Sources/Linear42Links.swift" 2>&1 | grep -v '^$' || true
"$out"
