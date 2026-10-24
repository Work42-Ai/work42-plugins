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
    publish-doc.py --issue WOR-6 --kind shape --file - <<'MD' ... MD     # "WOR-6 Product Shape" (Product Shape sessions)

Titles and icons: `<KEY> Spec` (📐), `<KEY> Testing Plan` (🧪), `<KEY> QA Report` (🧾), so documents on
different issues never look alike in Linear, and Work42's document widgets recognise them. The spec and
testing plan are authored in Planning only and the QA report in Testing; the session's workflow gates which
stage may run this script (no check here).

Prints `{"slug", "url"}` of the document. Any failure (a snapshot, an upload, a missing file or session id)
exits 1 BEFORE the document is touched, so a half-built document never replaces a good one.

Only the standard library; it calls the Work42 app's local artifact server over HTTP and shells out to `linear`,
`curl` and, for video posters, `ffmpeg`. It never runs a `work42` command.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

TOKEN = re.compile(r"^\[\[artifact:([a-z0-9][a-z0-9-]*)\]\]$")
FENCE = re.compile(r"^\s*(```|~~~)")
DOCUMENT_URL = re.compile(r"https://linear\.app/\S+?/document/(\S+)")
CACHE_FILE = ".linear-upload.json"
MEDIA = re.compile(r"!\[([^\]]*)\]\(((?:/|~/)[^)\s]+)\)")
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


def runtime_path():
    return os.path.expanduser("~/.work42/artifacts/runtime.json")


def snapshot_url(artifact_id, session_id):
    """The artifact server's snapshot URL for this session's artifact, from the app's runtime descriptor."""
    try:
        with open(runtime_path()) as handle:
            runtime = json.load(handle)
        port, secret = int(runtime["port"]), str(runtime["secret"])
    except (OSError, ValueError, KeyError, TypeError):
        raise Failure("the Work42 app isn't running; open it and retry")
    token = hashlib.sha256(("%s:%s" % (secret, session_id)).encode("utf-8")).hexdigest()[:20]
    return "http://127.0.0.1:%d/%s-%s/%s/snapshot.png?width=1000" % (port, session_id, token, artifact_id)


def snapshot(artifact_id, session_id, workdir):
    """Render the artifact to a PNG through the app's artifact server and return its path."""
    url = snapshot_url(artifact_id=artifact_id, session_id=session_id)
    out = os.path.join(workdir, artifact_id + ".png")
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise Failure("no artifact '%s' in this session" % artifact_id)
        raise Failure("snapshot of artifact '%s' failed (HTTP %d)" % (artifact_id, error.code))
    except (urllib.error.URLError, OSError) as error:
        raise Failure("couldn't reach the Work42 app to snapshot artifact '%s' (%s); open it and retry"
                      % (artifact_id, getattr(error, "reason", error)))
    with open(out, "wb") as handle:
        handle.write(data)
    return out


def artifact_dir(artifact_id):
    """`$WORK42_SESSION_DIR/artifacts/<id>/`, the session's own folder for this artifact."""
    session_dir = os.environ.get("WORK42_SESSION_DIR", "")
    if not session_dir:
        raise Failure("WORK42_SESSION_DIR isn't set; it is needed to find artifact '%s'" % artifact_id)
    return os.path.join(session_dir, "artifacts", artifact_id)


def cache_path(artifact_id):
    return os.path.join(artifact_dir(artifact_id), CACHE_FILE)


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


def asset_url_for(artifact_id, session_id, workdir):
    """The uploaded image URL for the artifact: reuse the last upload when the PNG is unchanged."""
    png = snapshot(artifact_id, session_id, workdir)
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


def artifact_titles(artifact_ids):
    """{artifact id: title} from each artifact's `meta.json` (the id when there is no readable title)."""
    titles = {}
    for artifact_id in artifact_ids:
        title = None
        try:
            with open(os.path.join(artifact_dir(artifact_id), "meta.json")) as handle:
                title = json.load(handle).get("title")
        except (OSError, ValueError, AttributeError, Failure):
            pass
        titles[artifact_id] = title if isinstance(title, str) and title.strip() else artifact_id
    return titles


def rewrite(lines, tokens, session_id, workdir):
    """The markdown with each artifact token line replaced by its title link and its linked image."""
    urls = {}
    for _, artifact_id in tokens:
        if artifact_id not in urls:
            urls[artifact_id] = asset_url_for(artifact_id, session_id, workdir)
    titles = artifact_titles(urls)
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
         "qa": ("QA Report", ":receipt:"), "shape": ("Product Shape", ":jigsaw:")}


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
                        help="spec -> '<KEY> Spec' (📐), testing -> '<KEY> Testing Plan' (🧪); "
                             "shape -> '<KEY> Product Shape' (🧩); qa -> '<KEY> QA Report' (🧾). "
                             "The workflow decides in which stage each may run.")
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
