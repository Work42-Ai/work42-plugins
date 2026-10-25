"""Tests for skills/linear42-general/publish-doc.py: the artifact server URL and token, a missing runtime,
a 404, the title fallback, the per-session cache path, and that no `work42` command is ever spawned.

Run with: python3 -m unittest discover -s Tests -p 'test_*.py'  (from work42-plugins/linear42).
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
import urllib.error
from unittest import mock

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "skills", "linear42-general", "publish-doc.py")
spec = importlib.util.spec_from_file_location("publish_doc", SCRIPT)
publish_doc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish_doc)


class FakeResponse:
    def __init__(self, data):
        self.data = data

    def read(self):
        return self.data

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Home(unittest.TestCase):
    """A throwaway $HOME holding ~/.work42/artifacts/runtime.json, and a session directory."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = os.path.join(self.tmp.name, "home")
        self.session_dir = os.path.join(self.tmp.name, "session")
        os.makedirs(os.path.join(self.home, ".work42", "artifacts"))
        os.makedirs(self.session_dir)
        env = mock.patch.dict(os.environ, {"HOME": self.home, "WORK42_SESSION_DIR": self.session_dir})
        env.start()
        self.addCleanup(env.stop)

    def write_runtime(self, port=4321, secret="s3cret"):
        with open(os.path.join(self.home, ".work42", "artifacts", "runtime.json"), "w") as handle:
            json.dump({"port": port, "secret": secret}, handle)

    def write_meta(self, artifact_id, meta):
        folder = os.path.join(self.session_dir, "artifacts", artifact_id)
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "meta.json"), "w") as handle:
            json.dump(meta, handle)


class SnapshotUrl(Home):
    def test_url_carries_session_token_and_width(self):
        self.write_runtime(port=4321, secret="s3cret")
        token = hashlib.sha256(b"s3cret:sess-1").hexdigest()[:20]
        self.assertEqual(len(token), 20)
        self.assertEqual(
            publish_doc.snapshot_url("layout", "sess-1"),
            "http://127.0.0.1:4321/sess-1-%s/layout/snapshot.png?width=1000" % token)

    def test_missing_runtime_says_the_app_is_not_running(self):
        with self.assertRaises(publish_doc.Failure) as caught:
            publish_doc.snapshot_url("layout", "sess-1")
        self.assertEqual(str(caught.exception), "the Work42 app isn't running; open it and retry")

    def test_unreadable_runtime_is_the_same_failure(self):
        with open(os.path.join(self.home, ".work42", "artifacts", "runtime.json"), "w") as handle:
            handle.write("not json")
        with self.assertRaises(publish_doc.Failure):
            publish_doc.snapshot_url("layout", "sess-1")


class Snapshot(Home):
    def test_writes_the_png_into_the_workdir(self):
        self.write_runtime()
        with tempfile.TemporaryDirectory() as workdir, \
                mock.patch.object(publish_doc.urllib.request, "urlopen", return_value=FakeResponse(b"PNGBYTES")) as opened:
            path = publish_doc.snapshot("layout", "sess-1", workdir)
            self.assertEqual(path, os.path.join(workdir, "layout.png"))
            with open(path, "rb") as handle:
                self.assertEqual(handle.read(), b"PNGBYTES")
        self.assertIn("/layout/snapshot.png?width=1000", opened.call_args[0][0])

    def test_404_names_the_artifact(self):
        self.write_runtime()
        error = urllib.error.HTTPError("http://x", 404, "Not Found", {}, None)
        with tempfile.TemporaryDirectory() as workdir, \
                mock.patch.object(publish_doc.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(publish_doc.Failure) as caught:
                publish_doc.snapshot("gone", "sess-1", workdir)
        self.assertEqual(str(caught.exception), "no artifact 'gone' in this session")

    def test_unreachable_server_asks_to_open_the_app(self):
        self.write_runtime()
        with tempfile.TemporaryDirectory() as workdir, \
                mock.patch.object(publish_doc.urllib.request, "urlopen", side_effect=urllib.error.URLError("refused")):
            with self.assertRaises(publish_doc.Failure) as caught:
                publish_doc.snapshot("layout", "sess-1", workdir)
        self.assertIn("open it and retry", str(caught.exception))


class Paths(Home):
    def test_cache_path_is_inside_the_session_directory(self):
        self.assertEqual(publish_doc.cache_path("layout"),
                         os.path.join(self.session_dir, "artifacts", "layout", ".linear-upload.json"))

    def test_missing_session_dir_fails_clearly(self):
        with mock.patch.dict(os.environ):
            del os.environ["WORK42_SESSION_DIR"]
            with self.assertRaises(publish_doc.Failure) as caught:
                publish_doc.cache_path("layout")
        self.assertIn("WORK42_SESSION_DIR", str(caught.exception))

    def test_titles_come_from_meta_and_fall_back_to_the_id(self):
        self.write_meta("one", {"title": "Layout One"})
        self.write_meta("blank", {"title": "  "})
        self.write_meta("untitled", {})
        titles = publish_doc.artifact_titles(["one", "blank", "untitled", "no-meta"])
        self.assertEqual(titles, {"one": "Layout One", "blank": "blank", "untitled": "untitled", "no-meta": "no-meta"})

    def test_titles_fall_back_to_ids_without_a_session_dir(self):
        with mock.patch.dict(os.environ):
            del os.environ["WORK42_SESSION_DIR"]
            self.assertEqual(publish_doc.artifact_titles(["one"]), {"one": "one"})


class NoWork42(Home):
    def test_source_never_names_the_work42_command(self):
        with open(SCRIPT) as handle:
            source = handle.read()
        self.assertNotIn('"work42"', source)
        self.assertNotIn("'work42'", source)
        self.assertNotIn("require_stage", source)

    def test_publishing_runs_only_linear_and_curl(self):
        self.write_runtime()
        self.write_meta("layout", {"title": "Layout"})
        commands = []

        def fake_run(command):
            commands.append(command[0])
            if command[0] == "linear" and command[1] == "api":
                payload = {"data": {"fileUpload": {"success": True, "uploadFile": {
                    "uploadUrl": "https://up", "assetUrl": "https://asset/1", "headers": []}}}}
                return mock.Mock(returncode=0, stdout=json.dumps(payload), stderr="")
            if command[0] == "curl":
                return mock.Mock(returncode=0, stdout="200", stderr="")
            return mock.Mock(returncode=0, stdout="https://linear.app/w/document/spec-abc123", stderr="")

        markdown = os.path.join(self.tmp.name, "spec.md")
        with open(markdown, "w") as handle:
            handle.write("# Spec\n\n[[artifact:layout]]\n")
        env = {"WORK42_SESSION_ID": "sess-1"}
        out = io.StringIO()
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(publish_doc, "run", side_effect=fake_run), \
                mock.patch.object(publish_doc.urllib.request, "urlopen", return_value=FakeResponse(b"PNG")), \
                contextlib.redirect_stdout(out):
            code = publish_doc.main(["--issue", "wor-6", "--kind", "spec", "--file", markdown])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out.getvalue())["slug"], "abc123")
        self.assertNotIn("work42", commands)
        self.assertEqual(set(commands), {"linear", "curl"})


if __name__ == "__main__":
    unittest.main()
