#!/usr/bin/env python3
"""Publish a markdown spec or testing plan to a Linear document.

Linear renders neither raw HTML nor iframes, so a Work42 artifact can't live in a document as
such. Every standalone `[[artifact:<id>]]` line becomes a screenshot of the artifact (uploaded to
Linear) followed by an "Open in Work42" link that reopens the live artifact in the app:

    ![artifact:<id>](<uploaded image url>)
    [Open in Work42](work42://session/<session id>/artifact/<id>)

    publish-doc.py --issue WOR-6 --kind spec --file spec.md            # create "WOR-6 Spec" on the issue
    publish-doc.py --issue WOR-6 --kind spec --file spec.md --slug 2838a00c306b   # update (renames, sets icon)
    publish-doc.py --issue WOR-6 --kind testing --file - <<'MD' ... MD   # "WOR-6 Testing Plan", markdown on stdin

The document is titled `<KEY> Spec` (icon 📐) or `<KEY> Testing Plan` (icon 🧪), so documents on different
issues never look alike in Linear, and Work42's Spec Document / Testing Plan Document widgets recognise them.

Planning blocks file writes, so agents normally pipe the markdown in with `--file -`.

Prints `{"slug", "url"}` of the document. Any failure (a snapshot, an upload, a missing session id)
exits 1 BEFORE the document is touched, so a half-built document never replaces a good one.

Only the standard library; it shells out to `work42`, `linear` and `curl`.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

TOKEN = re.compile(r"^\[\[artifact:([a-z0-9][a-z0-9-]*)\]\]$")
FENCE = re.compile(r"^\s*(```|~~~)")
DOCUMENT_URL = re.compile(r"https://linear\.app/\S+?/document/(\S+)")
CACHE_FILE = ".linear-upload.json"

UPLOAD_MUTATION = (
    "mutation($size: Int!, $filename: String!) { "
    'fileUpload(contentType: "image/png", filename: $filename, size: $size) '
    "{ success uploadFile { uploadUrl assetUrl headers { key value } } } }"
)


class Failure(Exception):
    """A step failed; the message is shown on stderr and the exit code is 1."""


def run(command):
    return subprocess.run(command, capture_output=True, text=True)


def log(message):
    print(message, file=sys.stderr)


def artifact_lines(lines):
    """(line index, artifact id) for every standalone token outside a fenced code block."""
    found = []
    in_fence = False
    for index, line in enumerate(lines):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        match = TOKEN.match(line.strip())
        if match:
            found.append((index, match.group(1)))
    return found


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot(artifact_id, workdir):
    """Render the artifact to a PNG (full page, 2x) and return its path."""
    out = os.path.join(workdir, artifact_id + ".png")
    result = run(["work42", "artifact", "snapshot", artifact_id, "--out", out, "--json"])
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise Failure("snapshot of artifact '%s' failed: %s" % (artifact_id, detail))
    return out


def cache_path(artifact_id):
    result = run(["work42", "artifact", "path", artifact_id])
    if result.returncode != 0:
        raise Failure("couldn't locate artifact '%s': %s" % (artifact_id, (result.stderr or result.stdout).strip()))
    return os.path.join(result.stdout.strip(), CACHE_FILE)


def read_cache(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def upload(png_path, artifact_id):
    """Upload the PNG through Linear's fileUpload and return the asset URL."""
    variables = json.dumps({"size": os.path.getsize(png_path), "filename": artifact_id + ".png"})
    result = run(["linear", "api", UPLOAD_MUTATION, "--variables-json", variables])
    if result.returncode != 0:
        raise Failure("couldn't start the upload of '%s': %s" % (artifact_id, (result.stderr or result.stdout).strip()))
    try:
        payload = json.loads(result.stdout)["data"]["fileUpload"]
        target = payload["uploadFile"]
        if not payload["success"]:
            raise KeyError("success")
        upload_url, asset_url, headers = target["uploadUrl"], target["assetUrl"], target["headers"]
    except (ValueError, KeyError, TypeError):
        raise Failure("unexpected fileUpload response for '%s': %s" % (artifact_id, result.stdout.strip()[:200]))

    command = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "PUT",
               "-H", "Content-Type: image/png", "-H", "Cache-Control: public, max-age=31536000"]
    for header in headers:
        command += ["-H", "%s: %s" % (header["key"], header["value"])]
    command += ["--data-binary", "@" + png_path, upload_url]
    result = run(command)
    if result.stdout.strip() != "200":
        raise Failure("uploading '%s' failed (HTTP %s)" % (artifact_id, result.stdout.strip() or "?"))
    return asset_url


def asset_url_for(artifact_id, workdir):
    """The uploaded image URL for the artifact: reuse the last upload when the PNG is unchanged."""
    png = snapshot(artifact_id, workdir)
    digest = sha256_of(png)
    cache = cache_path(artifact_id)
    cached = read_cache(cache)
    if cached.get("sha256") == digest and cached.get("assetUrl"):
        log("artifact %s: unchanged, reusing its upload" % artifact_id)
        return cached["assetUrl"]
    log("artifact %s: uploading" % artifact_id)
    url = upload(png, artifact_id)
    try:
        with open(cache, "w") as handle:
            json.dump({"sha256": digest, "assetUrl": url}, handle)
    except OSError:
        log("artifact %s: couldn't cache the upload (it will upload again next time)" % artifact_id)
    return url


def rewrite(lines, tokens, session_id, workdir):
    """The markdown with each artifact token line replaced by its image and link."""
    urls = {}
    for _, artifact_id in tokens:
        if artifact_id not in urls:
            urls[artifact_id] = asset_url_for(artifact_id, workdir)
    out = list(lines)
    for index, artifact_id in tokens:
        out[index] = "![artifact:%s](%s)\n\n[Open in Work42](work42://session/%s/artifact/%s)" % (
            artifact_id, urls[artifact_id], session_id, artifact_id)
    return out


KINDS = {"spec": ("Spec", "\U0001F4D0"), "testing": ("Testing Plan", "\U0001F9EA")}


def publish(args, markdown_path):
    label, icon = KINDS[args.kind]
    title = "%s %s" % (args.issue, label)
    if args.slug:
        command = ["linear", "document", "update", args.slug, "--title", title, "--icon", icon,
                   "--content-file", markdown_path]
    else:
        command = ["linear", "document", "create", "--issue", args.issue, "--title", title, "--icon", icon,
                   "--content-file", markdown_path]
    result = run(command)
    if result.returncode != 0:
        raise Failure("the Linear document wasn't published: %s" % (result.stderr or result.stdout).strip())
    match = DOCUMENT_URL.search(result.stdout)
    if not match:
        raise Failure("couldn't read the document URL from: %s" % result.stdout.strip()[:200])
    url = match.group(0)
    return {"slug": match.group(1).rsplit("-", 1)[-1], "url": url}


def main(argv):
    parser = argparse.ArgumentParser(description="Publish markdown to a Linear document (artifacts become images).")
    parser.add_argument("--issue", required=True, help="Issue key the document is attached to (e.g. WOR-6).")
    parser.add_argument("--kind", required=True, choices=sorted(KINDS),
                        help="spec -> '<KEY> Spec' (icon 📐), testing -> '<KEY> Testing Plan' (icon 🧪).")
    parser.add_argument("--file", required=True, help="Markdown file to publish, or - for stdin.")
    parser.add_argument("--slug", help="Update this existing document instead of creating one.")
    args = parser.parse_args(argv)
    args.issue = args.issue.strip().upper()

    try:
        if args.file == "-":
            lines = sys.stdin.read().split("\n")
        else:
            with open(args.file, encoding="utf-8") as handle:
                lines = handle.read().split("\n")
    except OSError as error:
        log("error: can't read --file: %s" % error)
        return 1

    tokens = artifact_lines(lines)
    session_id = os.environ.get("WORK42_SESSION_ID", "")
    try:
        if tokens and not session_id:
            raise Failure("WORK42_SESSION_ID isn't set; it is needed to link artifacts back to this session")
        with tempfile.TemporaryDirectory() as workdir:
            rewritten = rewrite(lines, tokens, session_id, workdir) if tokens else lines
            out_path = os.path.join(workdir, "document.md")
            with open(out_path, "w", encoding="utf-8") as handle:
                handle.write("\n".join(rewritten))
            document = publish(args, out_path)
    except Failure as failure:
        log("error: %s" % failure)
        return 1
    print(json.dumps(document))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
