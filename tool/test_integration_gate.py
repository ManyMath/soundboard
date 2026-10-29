#!/usr/bin/env python3
"""Exercise dependency gate against isolated Git fixtures, never Pub cache edits."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, cwd):
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=True).stdout.strip()


def main():
    original = json.loads((ROOT / ".dart_tool/package_config.json").read_text())
    # Resolve dependency URIs before moving package_config to the fixture root.
    from urllib.parse import urljoin
    for package in original["packages"]:
        package["rootUri"] = urljoin((ROOT / ".dart_tool/package_config.json").as_uri(), package["rootUri"])
    with tempfile.TemporaryDirectory(prefix="soundboard-integration-gate-") as temp:
        root = Path(temp)
        checkout = root / "dependency"
        package = checkout / "packages/fixture"
        sibling = checkout / "packages/sibling"
        package.mkdir(parents=True)
        sibling.mkdir()
        for directory in (package, sibling):
            (directory / "pubspec.yaml").write_text("name: fixture\nversion: 0.0.1\n")
            (directory / "source.txt").write_text("original")
        run("git", "init", "-q", cwd=checkout)
        run("git", "add", ".", cwd=checkout)
        run("git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture", cwd=checkout)
        revision = run("git", "rev-parse", "HEAD", cwd=checkout)
        (root / "tool").mkdir()
        shutil.copy2(ROOT / "tool/check_integration.dart", root / "tool/check_integration.dart")
        (root / "pubspec.yaml").write_text(f"workspace: []\ndependency_overrides:\n  fixture:\n    git:\n      url: ssh://git@git.manymath.com:2222/fixture/repo.git\n      path: packages/fixture\n      ref: {revision}\n")
        (root / "tool/integration.json").write_text(json.dumps({"dependencies": {"fixture": {"repository": "https://git.manymath.com/fixture/repo", "path": "packages/fixture", "revision": revision, "version": "0.0.1"}}}))
        (root / ".dart_tool").mkdir()
        original["packages"].append({"name": "fixture", "rootUri": package.as_uri() + "/", "packageUri": "lib/", "languageVersion": "3.10"})
        def check(expected, message=""):
            (root / ".dart_tool/package_config.json").write_text(json.dumps(original))
            result = subprocess.run([shutil.which("dart") or "dart", "--packages=" + str(root / ".dart_tool/package_config.json"), str(root / "tool/check_integration.dart")], cwd=root, text=True, capture_output=True)
            assert (result.returncode == 0) == expected, result.stdout + result.stderr
            assert message in result.stdout + result.stderr, result.stdout + result.stderr
        check(True)
        (package / "source.txt").write_text("modified")
        check(False, "modified or untracked source")
        (package / "source.txt").write_text("original")
        (package / "new_source.txt").write_text("untracked")
        check(False, "modified or untracked source")
        (package / "new_source.txt").unlink()
        original["packages"][-1]["rootUri"] = sibling.as_uri() + "/"
        check(False, "pinned subdirectory")
    print("PASS: clean pinned source accepted; modified, untracked and wrong-directory sources rejected")


if __name__ == "__main__":
    main()
