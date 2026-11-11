"""Exercise the production shell download path with deterministic local transport failures."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "build-runtime.sh"


class RuntimeFetchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.cache = self.root / "cache"
        self.locks = self.root / "locks"
        self.locks.mkdir()
        self.dest = self.cache / "payload.deb"
        self.payload = "locked fixture bytes\n"
        self.sha = self.digest(self.payload)
        self.primary = "https://mirror.invalid/pool/payload.deb"
        self.backup = "https://archive.invalid/payload.deb"
        self.routes = {}
        curl = self.bin / "curl"
        curl.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ["FETCH_TEST_ROOT"])
url = sys.argv[-1]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(url) + "\\n")
routes = json.loads((root / "routes.json").read_text())
status, body = routes.get(url, [22, "unmapped URL"])
Path(sys.argv[sys.argv.index("-o") + 1]).write_text(body)
sys.exit(status)
''')
        curl.chmod(0o755)

    @staticmethod
    def digest(body):
        return hashlib.sha256(body.encode()).hexdigest()

    def run_shell(self, entry, extra_env=None):
        source, marker, suffix = SCRIPT.read_text().rpartition('\nmain "$@"')
        self.assertTrue(marker and not suffix.strip(), "only omit the final build entrypoint")
        harness = self.root / "exercise.sh"
        harness.write_text(source + '\nCACHE="$FETCH_TEST_ROOT/cache"\n'
                           'LOCKS="$FETCH_TEST_ROOT/locks"\n' + entry + '\n')
        (self.root / "routes.json").write_text(json.dumps(self.routes))
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   FETCH_TEST_ROOT=str(self.root), RUNTIME_LAYERS="0", UPDATE_DEB_LOCK="0",
                   UBUNTU_EXTRA="tzdata ca-certificates git")
        env.update(extra_env or {})
        return subprocess.run(["bash", str(harness)], env=env, text=True,
                              capture_output=True, timeout=15)

    def fetch_entry(self, expected=None, conditional=False):
        expected = self.sha if expected is None else expected
        call = 'fetch "$PRIMARY" "$FETCH_TEST_ROOT/cache/payload.deb" "$EXPECTED" "$BACKUP"'
        if conditional:
            call = 'if ' + call + '; then printf "published"; fi'
        return call, dict(PRIMARY=self.primary, BACKUP=self.backup, EXPECTED=expected)

    def fetch(self, expected=None, conditional=False):
        entry, env = self.fetch_entry(expected, conditional)
        return self.run_shell(entry, env)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_verified_cache_needs_no_network(self):
        self.cache.mkdir()
        self.dest.write_text(self.payload)
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_primary_success_does_not_call_backup(self):
        self.routes[self.primary] = [0, self.payload]
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dest.read_text(), self.payload)
        self.assertEqual(self.calls(), [self.primary])

    def test_transport_failure_uses_backup_with_same_checksum(self):
        self.routes = {self.primary: [22, "partial"], self.backup: [0, self.payload]}
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dest.read_text(), self.payload)
        self.assertEqual(self.calls(), [self.primary, self.backup])

    def test_all_transports_fail_even_when_called_in_condition(self):
        self.routes = {self.primary: [22, "partial"], self.backup: [22, "also partial"]}
        result = self.fetch(expected="", conditional=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("published", result.stdout)
        self.assertFalse(self.dest.exists())
        self.assertEqual(self.calls(), [self.primary, self.backup])

    def test_wrong_primary_checksum_is_fatal_without_backup(self):
        self.routes = {self.primary: [0, "wrong bytes"], self.backup: [0, self.payload]}
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256 mismatch", result.stderr)
        self.assertFalse(self.dest.exists())
        self.assertEqual(self.calls(), [self.primary])

    def test_wrong_backup_checksum_is_fatal(self):
        self.routes = {self.primary: [22, "partial"], self.backup: [0, "wrong bytes"]}
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256 mismatch", result.stderr)
        self.assertFalse(self.dest.exists())
        self.assertEqual(self.calls(), [self.primary, self.backup])

    def test_existing_locks_use_fixed_basename_for_both_architectures(self):
        for arch, mirror in (("amd64", "https://mirrors.tuna.tsinghua.edu.cn/ubuntu"),
                             ("arm64", "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports")):
            with self.subTest(arch=arch):
                packages = []
                expected_calls = []
                expected_paths = []
                for package_arch in ("all", arch):
                    name = f"fixture-{arch}_1_{package_arch}.deb"
                    filename = f"pool/main/f/fixture/{name}"
                    body = f"fixture for {arch} {package_arch}"
                    packages.append(dict(filename=filename, sha256=self.digest(body)))
                    primary = f"{mirror}/{filename}"
                    backup = f"https://launchpad.net/ubuntu/+archive/primary/+files/{name}"
                    self.routes.update({primary: [22, "404"], backup: [0, body]})
                    expected_calls.extend([primary, backup])
                    expected_paths.append(str(self.cache / "ubuntu" / "debs" / name))
                lock = self.locks / f"ubuntu-noble-{arch}.json"
                original = json.dumps(dict(want=["tzdata", "ca-certificates", "git"], packages=packages))
                lock.write_text(original)
                before = self.calls()
                result = self.run_shell('ubuntu_extra_debs "$TEST_ARCH" /no-base-needed', {"TEST_ARCH": arch})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), expected_paths)
                self.assertEqual(self.calls()[len(before):], expected_calls)
                self.assertEqual(lock.read_text(), original)

    def test_failed_metadata_download_cannot_publish_from_command_substitution(self):
        name = "node-vfixture-linux-x64.tar.xz"
        checksums = "https://npmmirror.com/mirrors/node/vfixture/SHASUMS256.txt"
        self.routes = {checksums: [22, f"{self.sha}  {name}\n"],
                       f"https://npmmirror.com/mirrors/node/vfixture/{name}": [0, self.payload]}
        result = self.run_shell('NODE_VERSION=fixture\nvalue="$(node_dist x64)"\nprintf "published:%s" "$value"')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("published", result.stdout)
        self.assertEqual(self.calls(), [checksums])

    def test_python_mirror_still_falls_back_to_official(self):
        name = "cpython-fixture+fixture-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
        official = "https://github.com/astral-sh/python-build-standalone/releases/download/fixture"
        primary = "https://registry.npmmirror.com/-/binary/python-build-standalone/fixture/" + name
        self.routes = {official + "/SHA256SUMS": [0, f"{self.sha}  {name}\n"],
                       primary: [22, "partial"], official + "/" + name: [0, self.payload]}
        result = self.run_shell('PYTHON_VERSION=fixture\nPBS_RELEASE=fixture\nvalue="$(python_dist x86_64)"\nprintf "%s" "$value"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout).read_text(), self.payload)
        self.assertEqual(self.calls(), [official + "/SHA256SUMS", primary, official + "/" + name])

    def test_destination_setup_failure_cannot_report_success(self):
        self.cache.write_text("not a directory")
        result = self.fetch(expected="", conditional=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("published", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_failed_move_cannot_report_success(self):
        move = self.bin / "mv"
        move.write_text("#!/bin/sh\nexit 13\n")
        move.chmod(0o755)
        self.routes[self.primary] = [0, self.payload]
        result = self.fetch(expected="", conditional=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("published", result.stdout)
        self.assertFalse(self.dest.exists())


if __name__ == "__main__":
    unittest.main()
