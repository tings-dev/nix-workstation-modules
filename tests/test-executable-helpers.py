"""Exercise the real CLI with offline nix-locate and nix stand-ins."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "home/scripts/executable-helpers.py"


class ExecutableHelpersTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name, body in {
            "nix-locate": """
Path(os.environ['LOOKUP_LOG']).write_text(json.dumps(sys.argv[1:]))
print(os.environ.get('MATCHES', ''), end='')
sys.exit(int(os.environ.get('LOOKUP_STATUS', '0')))
""",
            "nix": """
Path(os.environ['RUN_LOG']).write_text(json.dumps(sys.argv[1:]))
sys.exit(int(os.environ.get('RUN_STATUS', '0')))
""",
        }.items():
            stub = self.root / name
            stub.write_text(
                f"#!{sys.executable}\nimport json, os, sys\nfrom pathlib import Path\n" + body
            )
            stub.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.root}:{os.environ['PATH']}",
            "LOOKUP_LOG": str(self.root / "lookup.json"),
            "RUN_LOG": str(self.root / "run.json"),
            "MATCHES": "",
            "LOOKUP_STATUS": "0",
            "RUN_STATUS": "0",
        }

    def run_helper(self, mode, *args, **env):
        return subprocess.run(
            [sys.executable, str(SCRIPT), mode, "path:/test/nixpkgs", *args],
            env={**self.env, **env}, capture_output=True, text=True,
        )

    def run_args(self):
        return json.loads((self.root / "run.json").read_text())

    def assert_not_run(self):
        self.assertFalse((self.root / "run.json").exists())

    def test_lexe_lists_sorted_distinct_packages_and_outputs(self):
        result = self.run_helper(
            "lexe", "demo", MATCHES="zulu.out\nalpha.bin\nalpha.bin\npython3Packages.demo.out\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "alpha^bin\npython3Packages.demo\nzulu\n")
        lookup = json.loads((self.root / "lookup.json").read_text())
        self.assertEqual(lookup[-2:], ["--", "/bin/demo"])
        for flag in ["--whole-name", "--at-root", "--no-group"]:
            self.assertIn(flag, lookup)
        self.assert_not_run()

    def test_single_result_runs_requested_name_and_preserves_arguments(self):
        result = self.run_helper(
            "rexe", "demo", "--flag", "two words", "", "$(touch nope)",
            MATCHES="different-package.out\ndifferent-package.out\n", RUN_STATUS="23",
        )
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(self.run_args(), [
            "shell", "path:/test/nixpkgs#different-package", "--command",
            "demo", "--flag", "two words", "", "$(touch nope)",
        ])

    def test_ambiguous_results_can_be_used_directly(self):
        result = self.run_helper("rexe", "demo", MATCHES="zulu.out\nalpha.bin\n")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "alpha^bin#demo\nzulu#demo\n")
        self.assert_not_run()
        chosen = result.stdout.splitlines()[0]
        result = self.run_helper("rexe", chosen, "argument")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_args(), [
            "shell", "path:/test/nixpkgs#alpha^bin", "--command", "demo", "argument",
        ])

    def test_explicit_package_skips_lookup(self):
        result = self.run_helper("rexe", "ripgrep#rg", "--version", LOOKUP_STATUS="42")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "lookup.json").exists())

    def test_single_nondefault_output(self):
        result = self.run_helper("rexe", "demo", MATCHES="example.bin\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_args()[1], "path:/test/nixpkgs#example^bin")

    def test_no_matches_does_not_run(self):
        for mode in ("lexe", "rexe"):
            result = self.run_helper(mode, "missing")
            self.assertEqual(result.returncode, 1)
            self.assertIn("no packages", result.stderr)
        self.assert_not_run()

    def test_lookup_failure_does_not_run_partial_results(self):
        result = self.run_helper("rexe", "demo", MATCHES="example.out\n", LOOKUP_STATUS="42")
        self.assertEqual(result.returncode, 42)
        self.assert_not_run()

    def test_usage_and_invalid_names(self):
        for mode, args in [
            ("lexe", []), ("rexe", []), ("lexe", ["demo", "extra"]),
            ("rexe", ["../demo"]), ("rexe", ["pkg#../demo"]),
            ("rexe", ["#demo"]), ("rexe", ["pkg#"]),
            ("rexe", ["pkg#demo#extra"]), ("lexe", ["demo\nextra"]),
        ]:
            with self.subTest(mode=mode, args=args):
                self.assertNotEqual(self.run_helper(mode, *args).returncode, 0)
        self.assert_not_run()


if __name__ == "__main__":
    unittest.main()
