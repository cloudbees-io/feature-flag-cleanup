"""Minimal mock of the GitHub Git Data API, backed by a real bare repository so that blob/tree/commit hashes are real.

Usage: mock_github.py PORT BARE_REPO_DIR LOG_FILE
"""
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, BARE, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
ENV = dict(os.environ, GIT_DIR=BARE, GIT_AUTHOR_NAME="mock", GIT_AUTHOR_EMAIL="mock@example.com",
           GIT_COMMITTER_NAME="mock", GIT_COMMITTER_EMAIL="mock@example.com")


def git(*args, stdin=None, env=ENV):
    return subprocess.run(["git", *args], input=stdin, env=env, check=True, capture_output=True).stdout


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        return raw, json.loads(raw)

    def do_GET(self):
        if m := re.search(r"/git/commits/(\w+)$", self.path):
            tree = git("rev-parse", m[1] + "^{tree}").decode().strip()
            return self.reply(200, {"sha": m[1], "tree": {"sha": tree}})
        if m := re.search(r"/git/refs/(heads/.+)$", self.path):
            found = subprocess.run(["git", "show-ref", "--verify", "--quiet", "refs/" + m[1]], env=ENV).returncode == 0
            return self.reply(200 if found else 404, {})
        self.reply(404, {"message": "not found"})

    def do_POST(self):
        raw, req = self.body()
        if self.path.endswith("/git/blobs"):
            content = base64.b64decode(req["content"], validate=True)
            assert req["encoding"] == "base64"
            if b"FAIL_BLOB" in content:
                return self.reply(422, {"message": "Validation Failed (mock)"})
            return self.reply(201, {"sha": git("hash-object", "-w", "--stdin", stdin=content).decode().strip()})
        if self.path.endswith("/git/trees"):
            with open(LOG, "a") as f:
                f.write(f"tree_request_bytes {len(raw)}\n")
            with tempfile.TemporaryDirectory() as tmp:
                env = dict(ENV, GIT_INDEX_FILE=os.path.join(tmp, "index"), GIT_WORK_TREE=tmp)
                git("read-tree", req["base_tree"], env=env)
                for e in req["tree"]:
                    if e["sha"] is None:
                        git("update-index", "--force-remove", "--", e["path"], env=env)
                    else:
                        git("update-index", "--add", "--cacheinfo", f"{e['mode']},{e['sha']},{e['path']}", env=env)
                return self.reply(201, {"sha": git("write-tree", env=env).decode().strip()})
        if self.path.endswith("/git/commits"):
            args = ["commit-tree", req["tree"], "-m", req["message"]]
            for parent in req["parents"]:
                args += ["-p", parent]
            return self.reply(201, {"sha": git(*args).decode().strip()})
        if self.path.endswith("/git/refs"):
            git("update-ref", req["ref"], req["sha"])
            return self.reply(201, {})
        self.reply(404, {"message": "not found"})

    def do_PATCH(self):
        _, req = self.body()
        if m := re.search(r"/git/refs/(heads/.+)$", self.path):
            git("update-ref", "refs/" + m[1], req["sha"])
            return self.reply(200, {})
        self.reply(404, {"message": "not found"})


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
