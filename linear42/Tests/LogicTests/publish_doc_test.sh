#!/bin/sh
# Tests skills/linear42-general/publish-doc.py with fake `linear`, `curl` and `ffmpeg` on PATH: the
# document kinds and icons, local images and videos, upload reuse and that an upload or missing-file failure
# exits non-zero before the Linear document is touched. The artifact path (runtime.json, token, snapshot URL,
# titles from meta.json) is covered by Tests/test_publish_doc.py; the stage guard is the workflow's now.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../../skills/linear42-general/publish-doc.py"
[ -f "$script" ] || { echo "FAIL: $script is missing"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/art"
LOG="$T/calls.log"

# --- fakes ---
cat > "$T/bin/linear" <<'EOF'
#!/bin/sh
echo "linear $*" >> "$FAKE_LOG"
case "$1" in
  api)
    n=$(cat "$FAKE_COUNTER" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$FAKE_COUNTER"
    fn=$(printf '%s' "$*" | sed -n 's/.*"filename": *"\([^"]*\)".*/\1/p')
    ct=$(printf '%s' "$*" | sed -n 's/.*"contentType": *"\([^"]*\)".*/\1/p')
    echo "contentType=$ct" >> "$FAKE_LOG"
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
cat > "$T/bin/ffmpeg" <<'EOF'
#!/bin/sh
# ffmpeg -y -loglevel error -ss <t> -i <video> -frames:v 1 <out>: writes a poster, except at -ss 1 when FAKE_SHORT is set.
echo "ffmpeg $*" >> "$FAKE_LOG"
ss=""; out=""
while [ $# -gt 0 ]; do [ "$1" = "-ss" ] && ss="$2"; out="$1"; shift; done
[ -n "${FAKE_SHORT:-}" ] && [ "$ss" = "1" ] && exit 0
printf 'POSTER-%s' "$ss" > "$out"
EOF
chmod +x "$T/bin/linear" "$T/bin/curl" "$T/bin/ffmpeg"

export PATH="$T/bin:$PATH" FAKE_LOG="$LOG" FAKE_ART="$T/art" FAKE_OUT="$T" FAKE_COUNTER="$T/counter"
export WORK42_SESSION_ID="sess-1" LINEAR42_UPLOAD_CACHE="$T/media-cache.json"

fail=0
check() { if eval "$2"; then :; else echo "FAIL: $1"; [ -n "${DEBUG:-}" ] && { echo "--- created.md"; cat "$T/created.md" 2>/dev/null; echo "--- calls"; tail -12 "$LOG"; }; fail=1; fi; }
reset() { : > "$LOG"; rm -f "$T/created.md" "$T/updated.md"; }
calls() { grep -c "$1" "$LOG" 2>/dev/null || true; }

# 8. no artifacts: no snapshot, no upload, still published ----------------------------------
reset
printf '# Plain\n\nNo artifacts here.\n' > "$T/plain.md"
env -u WORK42_SESSION_ID python3 "$script" --issue WOR-6 --kind qa --file "$T/plain.md" >/dev/null 2>&1; rc=$?
check "a plain QA report publishes without a session id" "[ $rc -eq 0 ] && [ -f '$T/created.md' ]"
check "no upload for a plain document" "[ \$(calls 'linear api') -eq 0 ]"
check "plain content is unchanged" "cmp -s '$T/plain.md' '$T/created.md'"

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
check "only spec, testing and qa are kinds" "[ $rc -ne 0 ]"

# 9. argument errors -------------------------------------------------------------------------
python3 "$script" --kind spec --file "$T/plain.md" >/dev/null 2>&1; rc=$?
check "missing --issue exits non-zero" "[ $rc -ne 0 ]"
python3 "$script" --issue WOR-6 --kind spec --file "$T/does-not-exist.md" >/dev/null 2>&1; rc=$?
check "a missing --file exits non-zero" "[ $rc -ne 0 ]"

# 10. the QA report kind -----------------------------------------------------------------------
reset
FAKE_STAGE=Testing python3 "$script" --issue WOR-6 --kind qa --file "$T/plain.md" >/dev/null 2>&1; rc=$?
check "a QA report publishes in Testing" "[ $rc -eq 0 ] && [ -f '$T/created.md' ]"
check "a QA report is titled <KEY> QA Report with the :receipt: icon" "grep -q 'linear document create .*--title WOR-6 QA Report .*--icon :receipt:' '$LOG'"
check "publishing runs no work42 command" "! grep -q 'work42' '$LOG'"
reset
FAKE_STAGE=Testing python3 "$script" --issue WOR-6 --kind qa --slug abc123def456 --file "$T/plain.md" >/dev/null 2>&1
check "the next round rewrites the same document" "grep -q 'linear document update abc123def456 .*--title WOR-6 QA Report' '$LOG'"

# 12. local images and videos -------------------------------------------------------------------
rm -f "$T/media-cache.json"
printf 'PNGDATA' > "$T/shot.png"; printf 'MOVDATA' > "$T/run.mov"; printf 'MP4DATA' > "$T/clip.mp4"; printf 'TXT' > "$T/notes.txt"
cat > "$T/qa.md" <<EOF
# QA Report

![AC1 approved](/$T/shot.png)

![AC2 recording]($T/run.mov)

![](/$T/clip.mp4)

![remote](https://example.com/a.png)

\`\`\`
![fenced]($T/shot.png)
\`\`\`
EOF
reset
FAKE_STAGE=Testing python3 "$script" --issue WOR-6 --kind qa --file "$T/qa.md" >/dev/null 2>"$T/err"; rc=$?
check "media publishes" "[ $rc -eq 0 ] && [ -f '$T/created.md' ]"
check "an image becomes the uploaded image" "grep -q '^!\[AC1 approved\](https://uploads.test/asset/shot.png-[0-9]*)\$' '$T/created.md'"
check "a video becomes a play link" "grep -q '^\[▶ AC2 recording\](https://uploads.test/asset/run.mov-[0-9]*)\$' '$T/created.md'"
check "the video's poster links to the video" "grep -q '^\[!\[AC2 recording\](https://uploads.test/asset/run.mov.png-[0-9]*)\](https://uploads.test/asset/run.mov-[0-9]*)\$' '$T/created.md'"
check "a video with no alt text is labelled with its file name" "grep -q '^\[▶ clip.mp4\](' '$T/created.md'"
check "each type is uploaded with its content type" "grep -q 'contentType=image/png' '$LOG' && grep -q 'contentType=video/quicktime' '$LOG' && grep -q 'contentType=video/mp4' '$LOG' && grep -q 'Content-Type: video/quicktime' '$LOG'"
check "the poster is taken at 1 s" "grep -q 'ffmpeg .*-ss 1 .*run.mov' '$LOG'"
check "a remote image is left alone" "grep -q '^!\[remote\](https://example.com/a.png)\$' '$T/created.md'"
check "an image inside a code fence is left alone" "grep -q '^!\[fenced\]($(echo "$T" | sed 's/[][\.*^$/]/\\&/g')/shot.png)\$' '$T/created.md'"
check "no local path is left in the document" "! grep -q '^!\[AC1' '$T/created.md' || ! grep -q '$T/shot.png)' '$T/created.md' || grep -q 'fenced' '$T/created.md'"

# unchanged files are not uploaded again
reset
FAKE_STAGE=Testing python3 "$script" --issue WOR-6 --kind qa --file "$T/qa.md" >/dev/null 2>&1
check "a second round re-uploads nothing" "[ \$(calls 'linear api') -eq 0 ] && [ \$(calls '^curl') -eq 0 ] && [ \$(calls '^ffmpeg') -eq 0 ]"
check "the same asset URLs are reused" "grep -q 'asset/shot.png-' '$T/created.md' && grep -q 'asset/run.mov-' '$T/created.md'"
reset
printf 'PNGDATA-v2' > "$T/shot.png"
FAKE_STAGE=Testing python3 "$script" --issue WOR-6 --kind qa --file "$T/qa.md" >/dev/null 2>&1
check "a changed file uploads again, the rest do not" "[ \$(calls 'linear api') -eq 1 ] && [ \$(calls '^curl') -eq 1 ]"

# a video shorter than a second still gets a poster (at 0 s)
rm -f "$T/media-cache.json"; reset
printf '![short](%s/clip.mp4)\n' "$T" > "$T/short.md"
FAKE_SHORT=1 FAKE_STAGE=Testing python3 "$script" --issue WOR-6 --kind qa --file "$T/short.md" >/dev/null 2>&1; rc=$?
check "a short video falls back to the first frame" "[ $rc -eq 0 ] && grep -q 'ffmpeg .*-ss 0 ' '$LOG'"

# failures leave the document untouched
rm -f "$T/media-cache.json"; reset
printf '![gone](%s/nope.png)\n' "$T" > "$T/missing.md"
FAKE_STAGE=Testing python3 "$script" --issue WOR-6 --kind qa --file "$T/missing.md" >/dev/null 2>"$T/err"; rc=$?
check "a missing file exits 1 and says which" "[ $rc -eq 1 ] && grep -q 'referenced file not found' '$T/err' && grep -q 'nope.png' '$T/err'"
check "no document call for a missing file" "[ \$(calls 'linear document') -eq 0 ]"
reset
printf '![notes](%s/notes.txt)\n' "$T" > "$T/odd.md"
FAKE_STAGE=Testing python3 "$script" --issue WOR-6 --kind qa --file "$T/odd.md" >/dev/null 2>"$T/err"; rc=$?
check "an unsupported media type exits 1" "[ $rc -eq 1 ] && grep -q 'unsupported media type' '$T/err' && [ \$(calls 'linear document') -eq 0 ]"
reset
FAKE_UPLOAD_FAIL=1 FAKE_STAGE=Testing python3 "$script" --issue WOR-6 --kind qa --file "$T/qa.md" >/dev/null 2>"$T/err"; rc=$?
check "a media upload failure exits 1 before the document is touched" "[ $rc -eq 1 ] && [ \$(calls 'linear document') -eq 0 ]"

if [ $fail -eq 0 ]; then echo "publish-doc tests: all passed"; else echo "publish-doc tests: FAILED"; exit 1; fi
