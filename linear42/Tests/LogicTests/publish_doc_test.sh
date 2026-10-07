#!/bin/sh
# Tests skills/linear42-general/publish-doc.py with fake `work42`, `linear` and `curl` on PATH:
# the markdown it publishes, upload reuse on an unchanged PNG, and that ANY snapshot or upload
# failure exits non-zero before the Linear document is touched.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../../skills/linear42-general/publish-doc.py"
[ -f "$script" ] || { echo "FAIL: $script is missing"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/art"
LOG="$T/calls.log"

# --- fakes ---------------------------------------------------------------------------------
cat > "$T/bin/work42" <<'EOF'
#!/bin/sh
# artifact snapshot <id> --out <path> --json   |   artifact path <id>
echo "work42 $*" >> "$FAKE_LOG"
[ "$1" = "artifact" ] || exit 2
case "$2" in
  snapshot)
    id="$3"; out=""
    while [ $# -gt 0 ]; do [ "$1" = "--out" ] && out="$2"; shift; done
    [ -n "${FAKE_SNAPSHOT_FAIL:-}" ] && { echo "boom" >&2; exit 1; }
    # Deterministic bytes per artifact; FAKE_BYTES_<id> changes them to simulate an edit.
    suffix="$(printenv "FAKE_BYTES_$(echo "$id" | tr '-' '_')" || true)"
    printf 'PNG-%s-%s' "$id" "$suffix" > "$out"
    echo "{\"path\":\"$out\",\"width\":2000,\"height\":1200}"
    ;;
  path)
    mkdir -p "$FAKE_ART/$3"; echo "$FAKE_ART/$3"
    ;;
esac
EOF
cat > "$T/bin/linear" <<'EOF'
#!/bin/sh
echo "linear $*" >> "$FAKE_LOG"
case "$1" in
  api)
    n=$(cat "$FAKE_COUNTER" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$FAKE_COUNTER"
    fn=$(printf '%s' "$*" | sed -n 's/.*"filename": *"\([^"]*\)\.png".*/\1/p')
    echo "{\"data\":{\"fileUpload\":{\"success\":true,\"uploadFile\":{\"uploadUrl\":\"https://upload.test/put/$n\",\"assetUrl\":\"https://uploads.test/asset/$fn-$n\",\"headers\":[{\"key\":\"x-goog-meta\",\"value\":\"v$n\"}]}}}}"
    ;;
  document)
    sub="$2"; file=""
    while [ $# -gt 0 ]; do { [ "$1" = "--content-file" ] || [ "$1" = "-f" ]; } && file="$2"; shift; done
    case "$sub" in
      create) cp "$file" "$FAKE_OUT/created.md" ;;
      update) cp "$file" "$FAKE_OUT/updated.md" ;;
    esac
    echo "✓ Created document T"
    echo "https://linear.app/work42/document/spec-abc123def456"
    ;;
esac
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$FAKE_LOG"
[ -n "${FAKE_UPLOAD_FAIL:-}" ] && { printf '500'; exit 0; }
printf '200'
EOF
chmod +x "$T/bin/work42" "$T/bin/linear" "$T/bin/curl"

export PATH="$T/bin:$PATH" FAKE_LOG="$LOG" FAKE_ART="$T/art" FAKE_OUT="$T" FAKE_COUNTER="$T/counter"
export WORK42_SESSION_ID="sess-1"

fail=0
check() { if eval "$2"; then :; else echo "FAIL: $1"; fail=1; fi; }
reset() { : > "$LOG"; rm -f "$T/created.md" "$T/updated.md"; }
calls() { grep -c "$1" "$LOG" 2>/dev/null || true; }

cat > "$T/spec.md" <<'EOF'
# Spec

Intro paragraph.

[[artifact:layout-one]]

Middle text with [[artifact:inline]] inside a sentence (must stay).

[[artifact:two]]

```
[[artifact:in-a-fence]]
```
EOF

# 1. rewrite + create ----------------------------------------------------------------------
reset
out="$(python3 "$script" --issue WOR-6 --kind spec --file "$T/spec.md" 2>"$T/err")"; rc=$?
check "create exits 0" "[ $rc -eq 0 ]"
check "prints the document slug and url" "printf '%s' '$out' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"slug\"]==\"abc123def456\" and d[\"url\"].endswith(\"spec-abc123def456\")'"
md="$T/created.md"
check "document was created" "[ -f '$md' ]"
check "first artifact becomes image + link" "grep -q '^!\[artifact:layout-one\](https://uploads.test/asset/layout-one-' '$md' && grep -q '^\[Open in Work42\](work42://session/sess-1/artifact/layout-one)\$' '$md'"
check "second artifact becomes image + link" "grep -q '^!\[artifact:two\](https://uploads.test/asset/two-' '$md' && grep -q 'artifact/two)' '$md'"
check "ordinary text is untouched" "grep -q '^Intro paragraph.\$' '$md'"
check "a token inside a sentence is not replaced" "grep -q 'Middle text with \[\[artifact:inline\]\] inside a sentence (must stay).' '$md'"
check "a token inside a code fence is not replaced" "grep -q '^\[\[artifact:in-a-fence\]\]\$' '$md'"
check "no snapshot for the inline or fenced tokens" "[ \$(calls 'snapshot inline') -eq 0 ] && [ \$(calls 'snapshot in-a-fence') -eq 0 ]"
check "document created with an issue" "grep -q 'linear document create .*--issue WOR-6' '$LOG'"
check "uploads send the signed header and content type" "grep -q 'x-goog-meta: v' '$LOG' && grep -q 'Content-Type: image/png' '$LOG'"
first_two="$(grep -o 'asset/two-[0-9]*' "$md")"

# 2. unchanged PNGs are not uploaded again --------------------------------------------------
reset
python3 "$script" --issue WOR-6 --kind spec --file "$T/spec.md" >/dev/null 2>&1; rc=$?
check "second run exits 0" "[ $rc -eq 0 ]"
check "no new upload when the PNG is unchanged" "[ \$(calls 'linear api') -eq 0 ] && [ \$(calls '^curl') -eq 0 ]"
check "the earlier asset URL is reused" "grep -q '$first_two' '$T/created.md'"

# 3. only the edited artifact re-uploads ----------------------------------------------------
reset
FAKE_BYTES_two="edited" python3 "$script" --issue WOR-6 --kind spec --file "$T/spec.md" >/dev/null 2>&1
check "one artifact changed, so exactly one upload" "[ \$(calls 'linear api') -eq 1 ] && [ \$(calls '^curl') -eq 1 ]"
check "the changed artifact has a new URL" "! grep -q '$first_two' '$T/created.md'"

# 4. update mode ----------------------------------------------------------------------------
reset
python3 "$script" --issue WOR-6 --kind spec --slug abc123def456 --file "$T/spec.md" >/dev/null 2>&1; rc=$?
check "update exits 0" "[ $rc -eq 0 ]"
check "update uses document update with the slug" "grep -q 'linear document update abc123def456 .*--content-file' '$LOG' && [ -f '$T/updated.md' ]"
check "update never uses --force" "! grep -q -- '--force' '$LOG'"

# 5. upload failure leaves the document untouched -------------------------------------------
rm -rf "$T/art"/*; mkdir -p "$T/art"; reset
FAKE_UPLOAD_FAIL=1 python3 "$script" --issue WOR-6 --kind spec --file "$T/spec.md" >/dev/null 2>"$T/err"; rc=$?
check "upload failure exits 1" "[ $rc -eq 1 ]"
check "no document call after an upload failure" "[ \$(calls 'linear document') -eq 0 ]"
check "the failure is explained on stderr" "[ -s '$T/err' ]"

# 6. snapshot failure leaves the document untouched -----------------------------------------
reset
FAKE_SNAPSHOT_FAIL=1 python3 "$script" --issue WOR-6 --kind spec --file "$T/spec.md" >/dev/null 2>"$T/err"; rc=$?
check "snapshot failure exits 1" "[ $rc -eq 1 ]"
check "no document call after a snapshot failure" "[ \$(calls 'linear document') -eq 0 ]"

# 7. artifact links need the session id -----------------------------------------------------
reset
env -u WORK42_SESSION_ID python3 "$script" --issue WOR-6 --kind spec --file "$T/spec.md" >/dev/null 2>"$T/err"; rc=$?
check "missing WORK42_SESSION_ID exits 1" "[ $rc -eq 1 ] && grep -qi 'WORK42_SESSION_ID' '$T/err'"
check "nothing ran without a session id" "[ \$(calls 'linear') -eq 0 ]"

# 8. no artifacts: no snapshot, no upload, still published ----------------------------------
reset
printf '# Plain\n\nNo artifacts here.\n' > "$T/plain.md"
env -u WORK42_SESSION_ID python3 "$script" --issue WOR-6 --kind spec --file "$T/plain.md" >/dev/null 2>&1; rc=$?
check "a plain document publishes without a session id" "[ $rc -eq 0 ] && [ -f '$T/created.md' ]"
check "no snapshot or upload for a plain document" "[ \$(calls 'work42') -eq 0 ] && [ \$(calls 'linear api') -eq 0 ]"
check "plain content is unchanged" "cmp -s '$T/plain.md' '$T/created.md'"

# 8b. content on stdin (Planning blocks file writes, so the skills pipe it in) ----------------
reset
python3 "$script" --issue WOR-6 --kind spec --file - >/dev/null 2>&1 <<'MD'
# Piped

[[artifact:two]]
MD
rc=$?
check "stdin content publishes" "[ $rc -eq 0 ] && [ -f '$T/created.md' ]"
check "stdin artifact tokens are rewritten" "grep -q '^!\[artifact:two\](https://uploads.test/asset/two-' '$T/created.md' && grep -q 'artifact/two)' '$T/created.md'"
check "the script is directly executable (stage rules match it by name)" "[ -x '$script' ] && head -1 '$script' | grep -q '^#!/usr/bin/env python3'"

# 8c. names and icons -------------------------------------------------------------------------
reset
python3 "$script" --issue WOR-6 --kind spec --file "$T/plain.md" >/dev/null 2>&1
check "a spec is titled <KEY> Spec with the :triangular_ruler: icon" "grep -q 'linear document create .*--title WOR-6 Spec .*--icon :triangular_ruler:' '$LOG'"
reset
python3 "$script" --issue WOR-7 --kind testing --file "$T/plain.md" >/dev/null 2>&1
check "a testing plan is titled <KEY> Testing Plan with the :test_tube: icon" "grep -q 'linear document create .*--title WOR-7 Testing Plan .*--icon :test_tube:' '$LOG'"
reset
python3 "$script" --issue WOR-6 --kind spec --slug abc123def456 --file "$T/plain.md" >/dev/null 2>&1
check "updating an old document renames it and sets the icon" "grep -q 'linear document update abc123def456 .*--title WOR-6 Spec .*--icon :triangular_ruler:' '$LOG'"
reset
python3 "$script" --issue wor-6 --kind spec --file "$T/plain.md" >/dev/null 2>&1
check "the issue key in the title is upper-cased" "grep -q -- '--title WOR-6 Spec' '$LOG'"
python3 "$script" --issue WOR-6 --title "Spec" --kind spec --file "$T/plain.md" >/dev/null 2>&1; rc=$?
check "--title is gone" "[ $rc -ne 0 ]"
python3 "$script" --issue WOR-6 --file "$T/plain.md" >/dev/null 2>&1; rc=$?
check "--kind is required" "[ $rc -ne 0 ]"
python3 "$script" --issue WOR-6 --kind notes --file "$T/plain.md" >/dev/null 2>&1; rc=$?
check "only spec and testing are kinds" "[ $rc -ne 0 ]"

# 9. argument errors -------------------------------------------------------------------------
python3 "$script" --kind spec --file "$T/plain.md" >/dev/null 2>&1; rc=$?
check "missing --issue exits non-zero" "[ $rc -ne 0 ]"
python3 "$script" --issue WOR-6 --kind spec --file "$T/does-not-exist.md" >/dev/null 2>&1; rc=$?
check "a missing --file exits non-zero" "[ $rc -ne 0 ]"

if [ $fail -eq 0 ]; then echo "publish-doc tests: all passed"; else echo "publish-doc tests: FAILED"; exit 1; fi
