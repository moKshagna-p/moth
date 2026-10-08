#!/usr/bin/env python3
"""Disposable, real-app Projects fixture. No Moth models or callbacks are mocked.

Run `python3 tests/e2e/projects-fixture.py setup`, then run projects.cua.js
through the Computer Use runner. Use `running` / `stopped` for external process
assertions. Quit Moth E2E before `cleanup`. Only the E2E bundle/profile is removed.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / ".codex/e2e-projects"
APP = WORK / "Moth E2E.app"
PROJECT = WORK / "Moth's E2E project"
BUNDLE_ID = "dev.moth.e2e.projects"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def setup():
    if WORK.exists():
        raise SystemExit("Fixture already exists. Quit Moth E2E, then run cleanup first.")
    source = ROOT / "target/release/Moth.app"
    if not source.exists():
        raise SystemExit("Build the app with scripts/build-app.sh first.")
    node = shutil.which("node")
    if not node:
        raise SystemExit("Node.js is required for the real dev-server fixture.")
    shutil.copytree(source, APP)
    plist_path = APP / "Contents/Info.plist"
    with plist_path.open("rb") as file:
        plist = plistlib.load(file)
    plist.update(CFBundleIdentifier=BUNDLE_ID, CFBundleName="Moth E2E",
                 CFBundleDisplayName="Moth E2E",
                 LSEnvironment={"MOTH_DATA_DIR": str(WORK / "browser-data")})
    with plist_path.open("wb") as file:
        plistlib.dump(plist, file)
    run("codesign", "--force", "--sign", "-", str(APP))
    PROJECT.mkdir()
    (PROJECT / "package.json").write_text(json.dumps({
        "name": "moth-e2e", "private": True, "scripts": {"dev": f'"{node}" server.cjs'}
    }))
    (PROJECT / "server.cjs").write_text("""
const http = require('node:http');
const fs = require('node:fs');
const {execFileSync} = require('node:child_process');
const branch = execFileSync('/usr/bin/git', ['branch', '--show-current'], {encoding:'utf8'}).trim();
const server = http.createServer((req, res) => {
  res.writeHead(200, {'Content-Type':'text/html'});
  res.end(`<title>Moth E2E ${branch}</title><h1>Real dev server: ${branch}</h1>`);
});
server.listen(Number(process.env.PORT), '127.0.0.1', () => {
  const port = server.address().port;
  fs.writeFileSync('run.json', JSON.stringify({pid:process.pid, port, branch, cwd:process.cwd()}));
  console.log(`Local: http://127.0.0.1:${port}`);
});
""")
    (PROJECT / ".gitignore").write_text("run.json\n")
    (PROJECT / "public").mkdir()
    shutil.copyfile(ROOT / "assets/Moth.icns", PROJECT / "public/favicon.ico")
    run("git", "init", "-b", "main", str(PROJECT))
    run("git", "-C", str(PROJECT), "add", ".")
    run("git", "-C", str(PROJECT), "-c", "user.name=Moth E2E", "-c",
        "user.email=e2e@localhost", "-c", "commit.gpgsign=false", "commit", "-m", "Fixture")
    run("git", "-C", str(PROJECT), "branch", "e2e-preview")
    print(json.dumps({"app": str(APP), "bundleID": BUNDLE_ID, "project": str(PROJECT)}, indent=2))


def check(running, collision=False):
    data = json.loads((PROJECT / "run.json").read_text())
    assert data["branch"] == "e2e-preview", data
    assert data["cwd"] == str(PROJECT.resolve()), data
    if collision:
        assert data["port"] != 3000, "Launcher did not skip the occupied port"
    assert run("git", "-C", str(PROJECT), "branch", "--show-current") == "e2e-preview"
    try:
        os.kill(data["pid"], 0)
        alive = True
    except ProcessLookupError:
        alive = False
    assert alive == running, f"Server PID {data['pid']} alive={alive}, expected {running}"
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(
                f"http://127.0.0.1:{data['port']}", timeout=2) as response:
            html = response.read().decode()
        responds = "Real dev server: e2e-preview" in html
    except OSError:
        responds = False
    assert responds == running, f"Server responds={responds}, expected {running}"
    print("PASS: real branch, working directory, server process and HTTP " + ("running" if running else "stopped"))


def occupy():
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"This is the already-running server, not the project.")
    with HTTPServer(("127.0.0.1", 3000), Handler) as server:
        print("Holding port 3000. Start the project, check running-collision, then interrupt this process.", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


def dirty():
    with (PROJECT / "server.cjs").open("a") as file:
        file.write("\n// Uncommitted work must survive a rejected branch switch.\n")


def blocked():
    assert not (PROJECT / "run.json").exists(), "A server started despite the dirty branch"
    assert run("git", "-C", str(PROJECT), "branch", "--show-current") == "main"
    assert "Uncommitted work" in (PROJECT / "server.cjs").read_text()
    assert run("git", "-C", str(PROJECT), "status", "--porcelain")
    print("PASS: branch unchanged, uncommitted work preserved, no server started")


def clean():
    # Restore only this generated file, never a user checkout.
    run("git", "-C", str(PROJECT), "restore", "server.cjs")


def cleanup():
    marker = PROJECT / "run.json"
    if marker.exists():
        data = json.loads(marker.read_text())
        try:
            os.kill(data["pid"], 0)
        except ProcessLookupError:
            pass
        else:
            raise SystemExit("Server is still alive. Stop it in Moth E2E before cleanup.")
    run("defaults", "delete", BUNDLE_ID) if subprocess.run(
        ["defaults", "read", BUNDLE_ID], capture_output=True).returncode == 0 else None
    if WORK.exists():
        shutil.rmtree(WORK)
    print("Removed only the disposable E2E project, bundle and preferences.")


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) == 2 else ""
    if action == "setup": setup()
    elif action in ("running", "stopped"): check(action == "running")
    elif action == "running-collision": check(True, collision=True)
    elif action == "occupy": occupy()
    elif action == "dirty": dirty()
    elif action == "blocked": blocked()
    elif action == "clean": clean()
    elif action == "cleanup": cleanup()
    else: raise SystemExit("Usage: projects-fixture.py setup|dirty|blocked|clean|running|running-collision|stopped|occupy|cleanup")
