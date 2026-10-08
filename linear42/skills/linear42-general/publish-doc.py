#!/usr/bin/env python3
"""Publish markdown to a Linear document: the spec, the testing plan or the QA report.

Linear renders neither raw HTML nor iframes, so a Work42 artifact can't live in a document as
such. Every standalone `[[artifact:<id>]]` line becomes the artifact's title as a link that reopens
the live artifact in the app, then a screenshot of it (uploaded to Linear) that links there too:

    [<artifact title>](work42://session/<session id>/artifact/<id>)

    [![<artifact title>](<uploaded image url>)](work42://session/<session id>/artifact/<id>)

Local media is uploaded too: `![alt](/abs/or/~/path)` naming an existing file becomes the uploaded
image, or, for a video, a `[▶ alt](<video>)` link followed by a poster frame linking to it.

    publish-doc.py --issue WOR-6 --kind spec --file spec.md            # create "WOR-6 Spec" on the issue
    publish-doc.py --issue WOR-6 --kind spec --file spec.md --slug 2838a00c306b   # update (renames, sets icon)
    publish-doc.py --issue WOR-6 --kind testing --file - <<'MD' ... MD   # "WOR-6 Testing Plan", markdown on stdin
    publish-doc.py --issue WOR-6 --kind qa --file - <<'MD' ... MD        # "WOR-6 QA Report"

Titles and icons: `<KEY> Spec` (📐), `<KEY> Testing Plan` (🧪), `<KEY> QA Report` (🧾), so documents on
different issues never look alike in Linear, and Work42's document widgets recognise them. The spec and
testing plan are authored in Planning only; the script refuses them in any other stage. The QA report is
written in Testing.

Prints `{"slug", "url"}` of the document. Any failure (a snapshot, an upload, a missing file or session id)
exits 1 BEFORE the document is touched, so a half-built document never replaces a good one.

Only the standard library; it shells out to `work42`, `linear`, `curl` and, for video posters, `ffmpeg`.
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
MEDIA = re.compile(r"!\[([^\]]*)\]\(((?:/|~/)[^)\s]+)\)")
PLANNING_ONLY = ("spec", "testing")
CONTENT_TYPES = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
    ".webp": "image/webp", ".mov": "video/quicktime", ".mp4": "video/mp4", ".webm": "video/webm",
}
VIDEO_TYPES = {".mov", ".mp4", ".webm"}

UPLOAD_MUTATION = (
    "mutation($size: Int!, $filename: String!, $contentType: String!) { "
    "fileUpload(contentType: $contentType, filename: $filename, size: $size) "
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


def upload(path, filename, content_type):
    """Upload a file through Linear's fileUpload and return the asset URL."""
    variables = json.dumps({"size": os.path.getsize(path), "filename": filename, "contentType": content_type})
    result = run(["linear", "api", UPLOAD_MUTATION, "--variables-json", variables])
    if result.returncode != 0:
        raise Failure("couldn't start the upload of '%s': %s" % (filename, (result.stderr or result.stdout).strip()))
    try:
        payload = json.loads(result.stdout)["data"]["fileUpload"]
        target = payload["uploadFile"]
        if not payload["success"]:
            raise KeyError("success")
        upload_url, asset_url, headers = target["uploadUrl"], target["assetUrl"], target["headers"]
    except (ValueError, KeyError, TypeError):
        raise Failure("unexpected fileUpload response for '%s': %s" % (filename, result.stdout.strip()[:200]))

    command = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "PUT",
               "-H", "Content-Type: " + content_type, "-H", "Cache-Control: public, max-age=31536000"]
    for header in headers:
        command += ["-H", "%s: %s" % (header["key"], header["value"])]
    command += ["--data-binary", "@" + path, upload_url]
    result = run(command)
    if result.stdout.strip() != "200":
        raise Failure("uploading '%s' failed (HTTP %s)" % (filename, result.stdout.strip() or "?"))
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
    url = upload(png, artifact_id + ".png", "image/png")
    try:
        with open(cache, "w") as handle:
            json.dump({"sha256": digest, "assetUrl": url}, handle)
    except OSError:
        log("artifact %s: couldn't cache the upload (it will upload again next time)" % artifact_id)
    return url


def artifact_titles():
    """{artifact id: title} from `work42 artifact list --json` (empty when it can't be read)."""
    result = run(["work42", "artifact", "list", "--json"])
    if result.returncode != 0:
        return {}
    try:
        return {item["id"]: item.get("title") or item["id"] for item in json.loads(result.stdout)}
    except (ValueError, KeyError, TypeError):
        return {}


def rewrite(lines, tokens, session_id, workdir):
    """The markdown with each artifact token line replaced by its title link and its linked image."""
    urls = {}
    for _, artifact_id in tokens:
        if artifact_id not in urls:
            urls[artifact_id] = asset_url_for(artifact_id, workdir)
    titles = artifact_titles()
    out = list(lines)
    for index, artifact_id in tokens:
        title = titles.get(artifact_id, artifact_id).replace("[", "(").replace("]", ")")
        link = "work42://session/%s/artifact/%s" % (session_id, artifact_id)
        out[index] = "[%s](%s)\n\n[![%s](%s)](%s)" % (title, link, title, urls[artifact_id], link)
    return out


def media_cache_path():
    return os.environ.get("LINEAR42_UPLOAD_CACHE") or os.path.expanduser("~/.cache/linear42/uploads.json")


def cached_upload(cache, key, make):
    """The asset URL cached under `key`, or the one `make()` uploads (and is then remembered)."""
    if cache.get(key):
        return cache[key]
    url = make()
    cache[key] = url
    try:
        os.makedirs(os.path.dirname(media_cache_path()), exist_ok=True)
        with open(media_cache_path(), "w") as handle:
            json.dump(cache, handle)
    except OSError:
        log("couldn't cache the upload (it will upload again next time)")
    return url


def poster_frame(video, workdir):
    """A PNG of the video at 1 s (at 0 s when it is shorter), or a Failure."""
    out = os.path.join(workdir, "poster-%s.png" % sha256_of(video)[:12])
    for seek in ("1", "0"):
        run(["ffmpeg", "-y", "-loglevel", "error", "-ss", seek, "-i", video, "-frames:v", "1", out])
        if os.path.isfile(out) and os.path.getsize(out) > 0:
            return out
    raise Failure("couldn't extract a poster frame from '%s' (is ffmpeg installed?)" % video)


def upload_media(path, workdir, cache, alt):
    """Markdown for one local media file: the image, or the video link plus its linked poster."""
    full = os.path.expanduser(path)
    if not os.path.isfile(full):
        raise Failure("referenced file not found: %s" % path)
    ext = os.path.splitext(full)[1].lower()
    if ext not in CONTENT_TYPES:
        raise Failure("unsupported media type '%s' for %s" % (ext or "(none)", path))
    label = alt or os.path.basename(full)
    digest = sha256_of(full)
    name = os.path.basename(full)
    asset = cached_upload(cache, digest, lambda: upload(full, name, CONTENT_TYPES[ext]))
    if ext not in VIDEO_TYPES:
        return "![%s](%s)" % (label, asset)
    poster = cached_upload(cache, "poster:" + digest,
                           lambda: upload(poster_frame(full, workdir), name + ".png", "image/png"))
    return "[▶ %s](%s)\n\n[![%s](%s)](%s)" % (label, asset, label, poster, asset)


def rewrite_media(lines, workdir):
    """The markdown with every local `![alt](/path)` reference outside a code fence uploaded."""
    cache = read_cache(media_cache_path())
    out = []
    in_fence = False
    for line in lines:
        if FENCE.match(line):
            in_fence = not in_fence
        elif not in_fence:
            line = MEDIA.sub(lambda m: upload_media(m.group(2), workdir, cache, m.group(1)), line)
        out.append(line)
    return out


# Linear takes the icon as an emoji shortcode (the emoji character itself is rejected).
KINDS = {"spec": ("Spec", ":triangular_ruler:"), "testing": ("Testing Plan", ":test_tube:"),
         "qa": ("QA Report", ":receipt:")}


def require_planning(session_id):
    """The spec and testing plan are authored in Planning only; refuse in any other stage."""
    if not session_id:
        raise Failure("WORK42_SESSION_ID isn't set; it is needed to check the session is in Planning")
    result = run(["work42", "session", "show", "--session", session_id, "--json"])
    try:
        stage = json.loads(result.stdout)["stage"] if result.returncode == 0 else None
    except (ValueError, KeyError, TypeError):
        stage = None
    if stage is None:
        raise Failure("couldn't read the session stage: %s" % (result.stderr or result.stdout).strip()[:200])
    if stage != "Planning":
        raise Failure("the spec and testing plan can only be published in Planning (this session is in %s)" % stage)


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
                        help="spec -> '<KEY> Spec' (📐), testing -> '<KEY> Testing Plan' (🧪), both Planning only; "
                             "qa -> '<KEY> QA Report' (🧾).")
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
        if args.kind in PLANNING_ONLY:
            require_planning(session_id)
        if tokens and not session_id:
            raise Failure("WORK42_SESSION_ID isn't set; it is needed to link artifacts back to this session")
        with tempfile.TemporaryDirectory() as workdir:
            rewritten = rewrite(lines, tokens, session_id, workdir) if tokens else lines
            rewritten = rewrite_media(rewritten, workdir)
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
