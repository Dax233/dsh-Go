#!/usr/bin/env python3
"""Unit tests for `rtbuild.py patch-dsh` (strict unified-diff application, per-version pins).

    python3 -I runtime/tests/test_patch_dsh.py
"""
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True   # runtime/lib/__pycache__ is tracked; do not rewrite it
HERE = os.path.dirname(os.path.abspath(__file__))
RTBUILD = os.path.join(HERE, "..", "lib", "rtbuild.py")
spec = importlib.util.spec_from_file_location("rtbuild", RTBUILD)
rtbuild = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rtbuild)

REL = "node_modules/@x/web/lib/index.js"
ORIGINAL = "".join("line %d\n" % i for i in range(1, 41)).replace("line 20\n", "\tif (route) {\n\t\tawait route.handler(req, res);\n\t}\n")
DIFF = """# comment lines before the first header are ignored
--- a/%s
+++ b/%s
@@ -19,4 +19,5 @@
 line 19
 \tif (route) {
+\t\tif (await guard(req, res)) return;
 \t\tawait route.handler(req, res);
 \t}
@@ -40,1 +41,2 @@
 line 40
+-- a removed-looking added line
""" % (REL, REL)
sha = lambda text: hashlib.sha256(text.encode()).hexdigest()


def read(path):
    with open(path) as f:
        return f.read()


def load(path):
    with open(path) as f:
        return json.load(f)


class PatchDsh(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.prefix = os.path.join(self.tmp.name, "prefix")
        self.patches = os.path.join(self.tmp.name, "patches")
        os.makedirs(os.path.join(self.prefix, os.path.dirname(REL)))
        os.makedirs(self.patches)
        self.target = os.path.join(self.prefix, REL)
        with open(self.target, "w") as f:
            f.write(ORIGINAL)
        with open(os.path.join(self.patches, "guard.diff"), "w") as f:
            f.write(DIFF)

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *extra):
        return subprocess.run([sys.executable, "-I", RTBUILD, "patch-dsh", "--prefix", self.prefix,
                               "--patches", self.patches, *extra],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                              env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})

    def test_parse_hunks(self):
        files = rtbuild.parse_unified_diff(DIFF)
        self.assertEqual([f[0] for f in files], [REL])
        (old1, new1), (old2, new2) = files[0][1]
        self.assertIn("\t\tif (await guard(req, res)) return;\n", new1)
        self.assertNotIn("guard", old1)
        self.assertEqual(new2, "line 40\n-- a removed-looking added line\n")

    def test_record_then_apply_pinned(self):
        r = self.run_cli("--dsh-version", "1.0.0", "--record")
        self.assertEqual(r.returncode, 0, r.stdout)
        pins = load(os.path.join(self.patches, "pins.json"))
        pin = pins["patches"]["guard.diff"]["1.0.0"][REL]
        self.assertEqual(pin["before"], sha(ORIGINAL))
        patched = read(self.target)
        self.assertEqual(pin["after"], sha(patched))
        self.assertIn("guard(req, res)", patched)
        # idempotent on an already patched tree
        r = self.run_cli("--dsh-version", "1.0.0")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("already patched", r.stdout)
        # a fresh original applies to exactly the pinned result, by replacing the file (hard links survive)
        with open(self.target + ".orig", "w") as f:
            f.write(ORIGINAL)
        os.replace(self.target + ".orig", self.target)
        link = self.target + ".link"
        os.link(self.target, link)
        r = self.run_cli("--dsh-version", "1.0.0", "--out", os.path.join(self.tmp.name, "applied.json"))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(sha(read(self.target)), pin["after"])
        self.assertEqual(read(link), ORIGINAL)
        self.assertEqual(load(os.path.join(self.tmp.name, "applied.json")), ["guard.diff"])

    def test_unpinned_version_fails(self):
        self.run_cli("--dsh-version", "1.0.0", "--record")
        with open(self.target, "w") as f:
            f.write(ORIGINAL)
        r = self.run_cli("--dsh-version", "1.0.1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no pin for DSH 1.0.1", r.stdout)
        self.assertEqual(read(self.target), ORIGINAL)

    def test_drifted_original_fails(self):
        self.run_cli("--dsh-version", "1.0.0", "--record")
        with open(self.target, "w") as f:
            f.write(ORIGINAL + "// upstream change\n")
        r = self.run_cli("--dsh-version", "1.0.0")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("differs from the vetted", r.stdout)

    def chain_fixture(self, broken=False):
        first = rtbuild.apply_hunks(ORIGINAL, rtbuild.parse_unified_diff(DIFF)[0][1], "first")
        second_diff = "--- a/%s\n+++ b/%s\n@@ -1,1 +1,1 @@\n-line 1\n+later reviewed patch\n" % (REL, REL)
        final = first.replace("line 1\n", "later reviewed patch\n", 1)
        with open(os.path.join(self.patches, "zz-later.diff"), "w") as out:
            out.write(second_diff)
        pins = {"schema": 1, "patches": {
            "guard.diff": {"1.0.0": {REL: {"before": sha(ORIGINAL), "after": sha(first)}}},
            "zz-later.diff": {"1.0.0": {REL: {"before": "0" * 64 if broken else sha(first), "after": sha(final)}}},
        }}
        with open(os.path.join(self.patches, "pins.json"), "w") as out:
            json.dump(pins, out)
        return first, final

    def test_ordered_hash_chain_is_idempotent_at_final_and_intermediate(self):
        first, final = self.chain_fixture()
        for starting in (ORIGINAL, first, final):
            with open(self.target, "w") as out:
                out.write(starting)
            result = self.run_cli("--dsh-version", "1.0.0")
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(read(self.target), final)

    def test_broken_hash_chain_fails_before_writing_any_file(self):
        self.chain_fixture(broken=True)
        result = self.run_cli("--dsh-version", "1.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken patch hash chain", result.stdout)
        self.assertEqual(read(self.target), ORIGINAL)

    def test_unknown_hash_is_not_accepted_by_chain_idempotency(self):
        _, final = self.chain_fixture()
        with open(self.target, "w") as out:
            out.write(final + "unexpected modification\n")
        result = self.run_cli("--dsh-version", "1.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from the vetted", result.stdout)

    def test_record_refuses_ambiguous_or_missing_context(self):
        with open(self.target, "w") as f:
            f.write(ORIGINAL + ORIGINAL)          # every hunk matches twice
        r = self.run_cli("--dsh-version", "2.0.0", "--record")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("matches 2 places", r.stdout)
        with open(self.target, "w") as f:
            f.write(ORIGINAL.replace("await route.handler", "await route.run"))
        r = self.run_cli("--dsh-version", "2.0.0", "--record")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("matches 0 places", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.patches, "pins.json")))

    def test_shipped_patch_parses_against_pins(self):
        shipped = os.path.join(HERE, "..", "patches")
        pins = load(os.path.join(shipped, "pins.json"))
        for name in sorted(n for n in os.listdir(shipped) if n.endswith(".diff")):
            files = rtbuild.parse_unified_diff(read(os.path.join(shipped, name)))
            self.assertTrue(files and all(hunks for _, hunks in files), name)
            for version, by_file in pins["patches"][name].items():
                self.assertEqual(sorted(by_file), sorted(rel for rel, _ in files), (name, version))

    @unittest.skipUnless(os.environ.get("DSH_FS_LOCAL_ORIGINAL_JS"),
                         "set DSH_FS_LOCAL_ORIGINAL_JS to the unpatched npm 0.2.1-rc.2 lib/index.js")
    def test_shipped_exclusive_create_patch_applies_and_rejects_drift(self):
        shipped = os.path.join(HERE, "..", "patches")
        name = "fs-create-exclusive.diff"
        rel = "node_modules/@deepseek-ai/dsh-fs-local/lib/index.js"
        pins = load(os.path.join(shipped, "pins.json"))
        pin = pins["patches"][name]["0.2.2-rc.1"][rel]
        with open(os.environ["DSH_FS_LOCAL_ORIGINAL_JS"], "rb") as source:
            original = source.read()
        self.assertEqual(hashlib.sha256(original).hexdigest(), pin["before"])
        target = os.path.join(self.prefix, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as out:
            out.write(original)
        os.remove(os.path.join(self.patches, "guard.diff"))
        with open(os.path.join(self.patches, name), "w") as out:
            out.write(read(os.path.join(shipped, name)))
        with open(os.path.join(self.patches, "pins.json"), "w") as out:
            json.dump({"schema": 1, "patches": {name: pins["patches"][name]}}, out)

        result = self.run_cli("--dsh-version", "0.2.2-rc.1")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(sha(read(target)), pin["after"])
        again = self.run_cli("--dsh-version", "0.2.2-rc.1")
        self.assertEqual(again.returncode, 0, again.stdout)
        self.assertIn("already patched", again.stdout)
        with open(target, "wb") as out:
            out.write(original + b"// upstream drift\n")
        changed = self.run_cli("--dsh-version", "0.2.2-rc.1")
        self.assertNotEqual(changed.returncode, 0)
        self.assertIn("differs from the vetted", changed.stdout)
        with open(target, "rb") as source:
            self.assertEqual(source.read(), original + b"// upstream drift\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
