#!/usr/bin/env bash
# release-plugin.sh — package, sign and notarize a Work42 plugin on this Mac, and optionally publish it as a GitHub Release.
#
#   scripts/release-plugin.sh [<plugin>] <version> --check      report readiness only; changes nothing
#   scripts/release-plugin.sh [<plugin>] <version>              build, sign, notarize into dist/<plugin>-<version>/
#   scripts/release-plugin.sh [<plugin>] <version> --publish    the same, then create the GitHub Release
#   scripts/release-plugin.sh [<plugin>] <version> --no-notarize  local check of the package step only (not publishable)
#
# Plugins are released from a Mac, never from CI: the Developer ID certificate and the notarization credentials stay in this
# Mac's keychain. `work42 plugin package` does the work: it signs every binary with the Developer ID Application identity,
# builds the extension, notarizes the zip with the `work42` notarytool profile and writes <plugin>-<version>.zip and
# release.json. This script adds the checks before it and the GitHub Release after it. When the marketplace exists, only the
# last step changes: the same zip and release.json are uploaded there instead.
#
# Two repository shapes:
#   a single-plugin repository (mail42, meet42): the plugin is ./work42-plugin, the tag is v<version>.
#   work42-plugins: <plugin> is a folder at the root, the tag is <plugin>-v<version>.
#
# `.work42-version` (one line, e.g. 1.4.2) names the Work42 release whose `work42` CLI packages the plugin. The CLI is read
# from $WORK42_APP (default /Applications/Work42.app); the script refuses an app whose version differs.
#
# One-time setup on this Mac (Yan): a Developer ID Application certificate in the login keychain, and
#   xcrun notarytool store-credentials work42 --apple-id <you> --team-id 74RFQFPVQ9
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root="$PWD"

die() { echo "error: $*" >&2; exit 1; }

plugin="" ; version="" ; check_only=false ; publish=false ; notarize=true
for arg in "$@"; do
  case "$arg" in
    --check) check_only=true ;;
    --publish) publish=true ;;
    --no-notarize) notarize=false ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    -*) die "unknown option $arg" ;;
    *) if [[ -z "$version" && "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then version="$arg"
       elif [[ -z "$plugin" && -z "$version" ]]; then plugin="$arg"
       else die "unexpected argument $arg"; fi ;;
  esac
done
[[ -n "$version" ]] || die "usage: scripts/release-plugin.sh [<plugin>] <version> [--check|--publish|--no-notarize]"
[[ "$publish" == false || "$notarize" == true ]] || die "--publish needs notarization; drop --no-notarize"

# Which repository shape is this?
if [[ -f work42-plugin/plugin.yaml ]]; then
  plugin_dir="work42-plugin"
  plugin="$(sed -n 's/^name:[[:space:]]*//p' "$plugin_dir/plugin.yaml" | head -n 1 | tr -d '"'"'"' ')"
  tag="v$version"
else
  [[ -n "$plugin" ]] || die "name the plugin: scripts/release-plugin.sh <plugin> $version"
  plugin_dir="$plugin"
  tag="$plugin-v$version"
fi
[[ -f "$plugin_dir/plugin.yaml" ]] || die "$plugin_dir/plugin.yaml not found"

app="${WORK42_APP:-/Applications/Work42.app}"
cli="$app/Contents/MacOS/work42"
notary_profile="${WORK42_NOTARY_PROFILE:-work42}"
out="dist/$plugin-$version"

# ---- readiness checks ---------------------------------------------------------------------------

ready=0 ; blocked=0
check() { # check "<label>" <command…>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ready=$((ready + 1)); printf 'READY    %s\n' "$label"
  else blocked=$((blocked + 1)); printf 'BLOCKED  %s\n' "$label"; fi
}

manifest_version() { sed -n 's/^version:[[:space:]]*//p' "$plugin_dir/plugin.yaml" | head -n 1 | tr -d '"'"'"' '; }
version_matches() { [[ "$(manifest_version)" == "$version" ]]; }
has_identity() { security find-identity -v -p codesigning | grep -Fq "Developer ID Application"; }
has_notary_profile() { xcrun notarytool history --keychain-profile "$notary_profile"; }
has_cli() { [[ -x "$cli" ]]; }
cli_version_pinned() {
  [[ -f .work42-version ]] || return 1
  [[ "$("$cli" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)" == "$(tr -d '[:space:]' < .work42-version)" ]]
}
clean_main() { [[ "$(git branch --show-current)" == main ]] && [[ -z "$(git status --porcelain)" ]]; }
synced_with_origin() { git fetch --quiet origin main && [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]]; }
tag_free() { [[ -z "$(git ls-remote --tags origin "refs/tags/$tag")" ]]; }
has_gh() { gh auth status; }

readiness_report() {
  printf '%s %s (tag %s) release readiness\n' "$plugin" "$version" "$tag"
  check "$plugin_dir/plugin.yaml says version $version" version_matches
  check "Developer ID Application identity in the login keychain" has_identity
  if [[ "$notarize" == true ]]; then check "notarytool profile '$notary_profile'" has_notary_profile; fi
  check "Work42 CLI at $cli" has_cli
  check ".work42-version matches the CLI's version" cli_version_pinned
  if [[ "$publish" == true || "$check_only" == true ]]; then
    check "clean checkout of main" clean_main
    check "main is up to date with origin" synced_with_origin
    check "tag $tag does not exist yet" tag_free
    check "GitHub CLI is logged in" has_gh
  fi
  printf '\nSummary: %s ready, %s blocked\n' "$ready" "$blocked"
  [[ "$blocked" -eq 0 ]]
}

if [[ "$check_only" == true ]]; then readiness_report; exit $?; fi
readiness_report || die "not ready — fix the BLOCKED items above, or run --check to see them again"

# ---- package ------------------------------------------------------------------------------------

rm -rf "$out"; mkdir -p "$out"
echo "==> package (sign$([[ "$notarize" == true ]] && echo ', notarize'))"
args=("$plugin_dir" --out "$out" --notary-profile "$notary_profile")
[[ "$notarize" == true ]] || args+=(--no-notarize)
"$cli" plugin package "${args[@]}"

zip="$out/$plugin-$version.zip"
[[ -f "$zip" && -f "$out/release.json" ]] || die "the package step did not write $zip and release.json"

echo "==> checksum"
(cd "$out" && shasum -a 256 "$plugin-$version.zip" | tee "$plugin-$version.zip.sha256")

if [[ "$publish" != true ]]; then
  echo
  echo "Ready in $out/ ($plugin-$version.zip, release.json). Not published: re-run with --publish."
  exit 0
fi

# ---- publish ------------------------------------------------------------------------------------

echo "==> tag $tag and create the GitHub Release"
git tag "$tag"
git push origin "$tag"
gh release create "$tag" "$zip" "$out/release.json" "$out/$plugin-$version.zip.sha256" \
  --title "$plugin $version" --notes "$plugin $version. Install with: work42 plugin install <link to $plugin-$version.zip>"
echo "Released $tag."
