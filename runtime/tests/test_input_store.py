"""Small local original-store tests; the npm integration never runs package scripts."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import urllib.error


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("input_store", REPO / "runtime/lib/input_store.py")
store = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(store)


def original(payload, urls=(), algorithm="sha256", size=None):
    digest = hashlib.new(algorithm, payload).hexdigest()
    return {"key": algorithm + "-" + digest, "algorithm": algorithm, "digest": digest,
            "urls": list(urls), "size": size, "refs": []}


class InputStoreTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="input-store-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cas = self.root / "store"

    def file(self, name, payload):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        return path

    def test_current_inventory_covers_two_abis_host_and_all_npm_locks(self):
        current = store.inventory(REPO)
        historical = store.inventory(REPO, all_locks=True)
        self.assertEqual(len(current), 723)
        self.assertEqual(len(historical), 1061)
        npm = [obj for obj in current if obj["algorithm"] == "sha512"]
        self.assertEqual(len(npm), 661)
        self.assertEqual(sum(len(obj["refs"]) for obj in npm), 662)
        self.assertEqual(sum(ref["optional"] for obj in npm for ref in obj["refs"]), 78)
        refs = [ref for obj in current for ref in obj["refs"]]
        self.assertEqual({ref["abi"] for ref in refs if ref["kind"] == "termux_jni"},
                         {"arm64-v8a", "x86_64"})
        self.assertEqual(sum(ref["kind"] == "node_guest_and_x64_build_host" for ref in refs), 1)
        self.assertTrue(all("license" in ref and ref["source"] for ref in refs))

    def test_inventory_reads_changed_pin_and_selected_lock(self):
        repo = self.root / "repo"
        (repo / "runtime").mkdir(parents=True)
        shell = (REPO / "runtime/build-runtime.sh").read_text()
        _, pins = store.shell_inputs(REPO)
        old = pins["proot-v5.1.107.98.zip"]
        (repo / "runtime/build-runtime.sh").write_text(shell.replace(old, "f" * 64))
        shutil.copytree(REPO / "runtime/locks", repo / "runtime/locks")
        lock = repo / "runtime/locks/pnpm-11.28.5/package-lock.json"
        selected = store.inventory(repo, [lock])
        self.assertEqual(len(selected), 63)
        self.assertIn("sha256-" + "f" * 64, {obj["key"] for obj in selected})
        self.assertNotIn("sha256-" + old, {obj["key"] for obj in selected})

    def test_npm_missing_integrity_fails_instead_of_silently_omitting(self):
        lock = self.file("lock.json", json.dumps({"packages": {
            "": {}, "node_modules/fixture": {"version": "1.0.0", "resolved": "https://example.invalid/a.tgz"},
        }}).encode())
        with self.assertRaisesRegex(store.InputError, "integrity"):
            store.npm_inventory([lock], self.root)

    def test_inventory_rejects_uncovered_and_unparsed_pin_entries(self):
        repo = self.root / "repo"
        (repo / "runtime").mkdir(parents=True)
        shutil.copytree(REPO / "runtime/locks", repo / "runtime/locks")
        shell = (REPO / "runtime/build-runtime.sh").read_text()
        for extra, message in (("  [new-fixed-input.tar.gz]=" + "0" * 64, "uncovered"),
                               ("  [new-fixed-input.tar.gz]=${SOURCE_HASH}", "unparsed")):
            with self.subTest(message=message):
                source = shell.replace("declare -A PIN=(\n", "declare -A PIN=(\n" + extra + "\n")
                (repo / "runtime/build-runtime.sh").write_text(source)
                with self.assertRaisesRegex(store.InputError, message):
                    store.inventory(repo)

    def test_current_pnpm_pin_and_lock_must_agree(self):
        repo = self.root / "repo"
        shell = (REPO / "runtime/build-runtime.sh").read_text()
        source = self.file("repo/runtime/build-runtime.sh", shell.encode())
        shutil.copytree(REPO / "runtime/locks", repo / "runtime/locks")
        values, _ = store.shell_inputs(repo)
        lock = repo / ("runtime/locks/pnpm-" + values["PNPM_VERSION"] + "/package-lock.json")
        replacement = "sha512-" + base64.b64encode(hashlib.sha512(b"changed source pin").digest()).decode()
        source.write_text(shell.replace(values["PNPM_INTEGRITY"], replacement))
        for all_locks in (False, True):
            with self.subTest(change="source integrity", all_locks=all_locks):
                with self.assertRaisesRegex(store.InputError, "pnpm.*pins"):
                    store.inventory(repo, all_locks=all_locks)
        source.write_text(shell)
        data = json.loads(lock.read_text())
        data["packages"]["node_modules/pnpm"]["version"] = "0.0.0-fixture"
        lock.write_text(json.dumps(data))
        for all_locks in (False, True):
            with self.subTest(change="lock version", all_locks=all_locks):
                with self.assertRaisesRegex(store.InputError, "pnpm.*pins"):
                    store.inventory(repo, all_locks=all_locks)

    def test_default_and_all_lock_selections_require_current_locks(self):
        repo = self.root / "repo"
        self.file("repo/runtime/build-runtime.sh", (REPO / "runtime/build-runtime.sh").read_bytes())
        shutil.copytree(REPO / "runtime/locks", repo / "runtime/locks")
        values, _ = store.shell_inputs(repo)
        defaults = [repo / ("runtime/locks/" + name + "/package-lock.json") for name in
                    ("dsh-" + values["DSH_VERSION"], "pnpm-" + values["PNPM_VERSION"])]
        selected = self.file("selected-lock.json", defaults[1].read_bytes())
        for missing in defaults:
            raw = missing.read_bytes()
            missing.unlink()
            for all_locks in (False, True):
                with self.subTest(missing=missing.parent.name, all_locks=all_locks):
                    with self.assertRaises(FileNotFoundError):
                        store.inventory(repo, all_locks=all_locks)
            missing.write_bytes(raw)
        for path in defaults:
            path.unlink()
        # Explicit selection replaces default npm locks; it is not a full-default claim.
        self.assertEqual(len(store.inventory(repo, [selected])), 63)

    def test_collect_original_bytes_under_extensionless_digest_name(self):
        source = self.file("origin.data", b"original archive bytes")
        obj = original(source.read_bytes(), [source.as_uri()], size=source.stat().st_size)
        result = store.collect_objects([obj], self.cas)
        self.assertFalse(result["errors"])
        self.assertIn("自留回落不可用", result["self_mirror"])
        self.assertEqual(result["collected"], 1)
        self.assertEqual((self.cas / obj["key"]).read_bytes(), source.read_bytes())
        self.assertEqual([path.name for path in self.cas.iterdir()], [obj["key"]])

    def test_cached_object_is_reverified_without_network(self):
        obj = original(b"already retained", ["https://example.invalid/a.tgz"])
        self.file("store/" + obj["key"], b"already retained")
        with patch.object(store.urllib.request, "urlopen") as opener:
            result = store.collect_objects([obj], self.cas)
        opener.assert_not_called()
        self.assertEqual(result["cached"], 1)
        (self.cas / obj["key"]).write_bytes(b"corrupted")
        with patch.object(store.urllib.request, "urlopen") as opener:
            result = store.collect_objects([obj], self.cas)
        opener.assert_not_called()
        self.assertTrue(result["errors"])
        self.assertTrue(result["stopped"])

    def test_transport_failure_uses_explicit_flat_mirror(self):
        payload = b"mirror original"
        obj = original(payload, [(self.root / "gone").as_uri()])
        self.file("mirror/" + obj["key"], payload)
        result = store.collect_objects([obj], self.cas, (self.root / "mirror").as_uri())
        self.assertEqual(result["collected"], 1)
        self.assertFalse(result["errors"])
        self.assertEqual((self.cas / obj["key"]).read_bytes(), payload)

    def test_http_protocol_open_error_uses_mirror_or_returns_json_error(self):
        payload = b"retained original"
        obj = original(payload, ["https://example.invalid/archive"])
        self.file("mirror/" + obj["key"], payload)
        opener = store.urllib.request.urlopen

        def open_source(request, **kwargs):
            if request.full_url.startswith("https:"):
                raise store.http.client.BadStatusLine("synthetic invalid status")
            return opener(request, **kwargs)

        with patch.object(store.urllib.request, "urlopen", side_effect=open_source) as calls:
            result = store.collect_objects([obj], self.cas, (self.root / "mirror").as_uri())
        self.assertFalse(result["errors"])
        self.assertEqual(calls.call_count, 2)
        self.assertEqual((self.cas / obj["key"]).read_bytes(), payload)
        output = io.StringIO()
        with patch.object(store, "inventory", return_value=[obj]), \
                patch.object(store.urllib.request, "urlopen", side_effect=open_source), \
                contextlib.redirect_stdout(output):
            code = store.main(["collect", "--store", str(self.root / "missing-store")])
        self.assertEqual(code, 1)
        self.assertIn("BadStatusLine", json.loads(output.getvalue())["errors"][0]["error"])

    def test_wrong_checksum_stops_without_mirror_or_later_object(self):
        wrong = self.file("wrong", b"wrong")
        obj = original(b"expected", [wrong.as_uri()])
        later = original(b"next", ["https://example.invalid/next"])
        self.file("mirror/" + obj["key"], b"expected")
        opener = store.urllib.request.urlopen
        with patch.object(store.urllib.request, "urlopen", wraps=opener) as calls:
            result = store.collect_objects([obj, later], self.cas, (self.root / "mirror").as_uri())
        self.assertEqual(calls.call_count, 1)
        self.assertTrue(result["stopped"])
        self.assertIn("checksum mismatch", result["errors"][0]["error"])
        self.assertFalse(list(self.cas.iterdir()))

    def test_partial_read_can_fall_back_and_leaves_no_partial_file(self):
        payload = b"complete bytes"
        obj = original(payload, ["https://example.invalid/archive"])
        self.file("mirror/" + obj["key"], payload)

        class BrokenRead(io.BytesIO):
            def read(self, count):
                if self.tell():
                    raise OSError("connection interrupted")
                return super().read(3)

        opener = store.urllib.request.urlopen

        def open_source(request, **kwargs):
            if request.full_url.startswith("https:"):
                return BrokenRead(payload)
            return opener(request, **kwargs)

        with patch.object(store.urllib.request, "urlopen", side_effect=open_source):
            result = store.collect_objects([obj], self.cas, (self.root / "mirror").as_uri())
        self.assertFalse(result["errors"])
        self.assertEqual([path.name for path in self.cas.iterdir()], [obj["key"]])

    def test_unavailable_reports_missing_without_publishing(self):
        obj = original(b"missing", [(self.root / "does-not-exist").as_uri()])
        result = store.collect_objects([obj], self.cas)
        self.assertEqual(result["collected"], 0)
        self.assertIn("unavailable", result["errors"][0]["error"])
        self.assertFalse(self.cas.exists())

    def test_size_and_atomic_replace_failures_do_not_publish(self):
        for size, fail_replace in ((100, False), (4, True)):
            with self.subTest(size=size):
                obj = original(b"data", size=size)
                with patch.object(store.os, "replace", side_effect=OSError("disk failure")) as replace:
                    with self.assertRaises((store.InputError, OSError)):
                        store.store_stream(io.BytesIO(b"data"), obj, self.cas)
                self.assertEqual(replace.call_count, int(fail_replace))
                self.assertFalse(list(self.cas.iterdir()))

    def test_import_identifies_bytes_not_names_and_verify_reports_all_errors(self):
        known = original(b"pinned archive")
        other = original(b"another archive")
        missing = original(b"never imported")
        path = self.file("misleading-cache-name", b"pinned archive")
        result = store.import_files([known, other, missing], [path], self.cas)
        self.assertEqual(result["imported"], 1)
        self.assertFalse(result["errors"])
        self.assertEqual(store.import_files([known], [path], self.cas)["cached"], 1)
        unknown = self.file("unknown", b"not in any lock")
        self.assertTrue(store.import_files([known], [unknown], self.cas)["errors"])
        self.file("store/" + other["key"], b"corrupt")
        result = store.verify_objects([known, other, missing], self.cas)
        self.assertEqual(result["verified"], 1)
        self.assertEqual(len(result["errors"]), 2)

    def test_mirror_is_explicit_https_or_local_file_base(self):
        for value in ("http://example.invalid/store", "https://user:pass@example.invalid/store",
                      "file://remote-host/store", "https://example.invalid/store?token=value"):
            with self.subTest(value=value), self.assertRaises(store.InputError):
                store.checked_url(value, base=True)
        self.assertEqual(store.checked_url(self.root.as_uri(), base=True), self.root.as_uri() + "/")

    def test_cli_has_machine_readable_nonzero_error(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = store.main(["inventory", "--repo", str(self.root / "absent")])
        self.assertEqual(code, 1)
        self.assertTrue(json.loads(output.getvalue())["errors"])

    def test_warm_requires_empty_explicit_npm_configs(self):
        lock = self.file("lock.json", b'{"packages":{}}')
        config = self.file("npmrc", b"registry=https://example.invalid\n")
        with patch.object(store.subprocess, "run") as run:
            with self.assertRaisesRegex(store.InputError, "empty"):
                store.warm_npm(lock, self.root, self.cas, self.root.as_uri(),
                               self.root / "npm", self.root / "cache", config, config)
        run.assert_not_called()

    def test_warm_batches_and_npm_failure_remove_only_temporary_aliases(self):
        packages = {"": {}}
        for index in range(65):
            payload = ("synthetic original " + str(index)).encode()
            digest = hashlib.sha512(payload)
            key = "sha512-" + digest.hexdigest()
            self.file("store/" + key, payload)
            packages["node_modules/fixture-" + str(index)] = {
                "version": "1.0.0", "resolved": "https://example.invalid/unused.tgz",
                "integrity": "sha512-" + base64.b64encode(digest.digest()).decode(),
            }
        lock = self.file("lock.json", json.dumps({"packages": packages}).encode())
        before = lock.read_bytes()
        config = self.file("empty-npmrc", b"")
        batch_sizes = []

        def cache_add(command, **kwargs):
            aliases = command[3:command.index("--offline")]
            batch_sizes.append(len(aliases))
            for value in aliases:
                path = Path(value)
                self.assertEqual(path.suffix, ".tgz")
                self.assertEqual(path.stat().st_ino, (self.cas / path.stem).stat().st_ino)
            return subprocess.CompletedProcess(command, 0 if len(batch_sizes) == 1 else 23)

        with patch.object(store.subprocess, "run", side_effect=cache_add):
            result = store.warm_npm(lock, self.root, self.cas, self.root.as_uri(),
                                    self.root / "npm", self.root / "cache", config, config)
        self.assertEqual(batch_sizes, [64, 1])
        self.assertEqual(result["npm_batches"], 1)
        self.assertEqual(result["errors"], [{"error": "npm cache add failed", "exit_code": 23}])
        self.assertEqual(lock.read_bytes(), before)
        self.assertEqual(len(list(self.cas.iterdir())), 65)
        self.assertTrue(all(path.is_file() for path in self.cas.iterdir()))

    def test_warm_checksum_failure_does_not_start_npm(self):
        raw = self.file("origin", b"wrong bytes")
        lock = self.file("lock.json", json.dumps({"packages": {"node_modules/fixture": {
            "version": "1.0.0", "resolved": raw.as_uri(),
            "integrity": "sha512-" + base64.b64encode(hashlib.sha512(b"expected bytes").digest()).decode(),
        }}}).encode())
        config = self.file("empty-npmrc", b"")
        with patch.object(store.subprocess, "run") as run:
            result = store.warm_npm(lock, self.root, self.cas, self.root.as_uri(),
                                    self.root / "npm", self.root / "cache", config, config)
        self.assertIn("checksum mismatch", result["errors"][0]["error"])
        run.assert_not_called()

    def test_real_npm_warms_extensionless_cas_then_installs_offline(self):
        npm_name = os.environ.get("INPUT_STORE_TEST_NPM") or shutil.which("npm")
        if not npm_name:
            self.skipTest("npm absent; set INPUT_STORE_TEST_NPM to an existing host npm")
        npm = Path(npm_name).absolute()
        userconfig = self.file("empty-user-npmrc", b"")
        globalconfig = self.file("empty-global-npmrc", b"")
        project = self.root / "project"
        project.mkdir()
        dependencies = {"store-fixture-one": "1.0.0", "store-fixture-two": "1.0.0"}
        packages = {"": {"name": "store-fixture-project", "version": "1.0.0", "dependencies": dependencies}}
        for name in dependencies:
            archive = io.BytesIO()
            files = {"package/package.json": json.dumps({"name": name, "version": "1.0.0",
                     "scripts": {"postinstall": "exit 99"}}).encode(),
                     "package/payload.txt": ("local payload: " + name).encode()}
            with tarfile.open(fileobj=archive, mode="w:gz") as tar:
                for filename, payload in files.items():
                    info = tarfile.TarInfo(filename)
                    info.size = len(payload)
                    tar.addfile(info, io.BytesIO(payload))
            raw = archive.getvalue()
            obj = original(raw, algorithm="sha512")
            self.file("mirror/" + obj["key"], raw)
            packages["node_modules/" + name] = {
                "version": "1.0.0", "resolved": "https://example.invalid/" + name + "-1.0.0.tgz",
                "integrity": "sha512-" + base64.b64encode(hashlib.sha512(raw).digest()).decode(),
                "license": "MIT", "hasInstallScript": True,
            }
        self.file("project/package.json", json.dumps({"name": "store-fixture-project", "version": "1.0.0",
                  "dependencies": dependencies}).encode())
        lock = self.file("project/package-lock.json", json.dumps({"name": "store-fixture-project", "version": "1.0.0",
                        "lockfileVersion": 3, "requires": True, "packages": packages}).encode())
        before = lock.read_bytes()
        cache = self.root / "npm-cache"
        opener = store.urllib.request.urlopen

        def unavailable_primary(request, **kwargs):
            if request.full_url.startswith("https:"):
                raise urllib.error.HTTPError(request.full_url, 404, "synthetic primary unavailable", {}, None)
            return opener(request, **kwargs)

        with patch.object(store.urllib.request, "urlopen", side_effect=unavailable_primary):
            result = store.warm_npm(lock, self.root, self.cas, (self.root / "mirror").as_uri(),
                                    npm, cache, userconfig, globalconfig)
        self.assertFalse(result["errors"], result)
        self.assertEqual(result["npm_batches"], 1)
        self.assertEqual(result["collected"], 2)
        self.assertEqual(lock.read_bytes(), before)
        self.assertTrue(all(path.name.startswith("sha512-") and not path.suffix for path in self.cas.iterdir()))
        environment = os.environ.copy()
        environment["PATH"] = str(npm.parent) + os.pathsep + environment.get("PATH", "")
        completed = subprocess.run([str(npm), "ci", "--offline", "--ignore-scripts", "--no-audit", "--no-fund",
                                    "--cache", str(cache), "--userconfig", str(userconfig),
                                    "--globalconfig", str(globalconfig)], cwd=project, env=environment,
                                   capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertEqual(lock.read_bytes(), before)
        for name in dependencies:
            self.assertEqual((project / "node_modules" / name / "payload.txt").read_text(), "local payload: " + name)


if __name__ == "__main__":
    unittest.main()
