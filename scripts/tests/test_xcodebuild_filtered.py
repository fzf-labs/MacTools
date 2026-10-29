import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
FINGERPRINT = "0123456789ABCDEF0123456789ABCDEF01234567"


class XcodebuildFilteredTests(unittest.TestCase):
    def run_build(self, *arguments: str) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ("xcodebuild-filtered.sh", "validate-local-debug-config.sh"):
                shutil.copy2(REPO_ROOT / "scripts" / name, scripts / name)
            (root / "LocalConfig.xcconfig").write_text(
                "DEVELOPMENT_TEAM =\nBUNDLE_IDENTIFIER_PREFIX = org.exampledeveloper\n"
                f"LOCAL_CODE_SIGN_IDENTITY = {FINGERPRINT}\n", encoding="utf-8"
            )
            capture = root / "arguments.json"
            fake = root / "xcodebuild"
            fake.write_text(
                "#!/usr/bin/python3\nimport json, os, pathlib, sys\n"
                "pathlib.Path(os.environ['CAPTURE']).write_text(json.dumps(sys.argv[1:]))\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            environment = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "CAPTURE": str(capture)}
            result = subprocess.run(
                [str(scripts / "xcodebuild-filtered.sh"), *arguments],
                env=environment, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(capture.read_text(encoding="utf-8"))

    def test_uses_pinned_certificate_for_debug(self) -> None:
        arguments = self.run_build("-configuration", "Debug", "build")
        self.assertIn(f"CODE_SIGN_IDENTITY={FINGERPRINT}", arguments)
        self.assertIn("CODE_SIGN_STYLE=Manual", arguments)
        self.assertIn("DEVELOPMENT_TEAM=", arguments)

    def test_preserves_explicit_signing_and_unsigned_test_builds(self) -> None:
        for signing in ("CODE_SIGNING_ALLOWED=NO", "CODE_SIGN_IDENTITY=explicit"):
            with self.subTest(signing=signing):
                arguments = ["-configuration", "Debug", signing, "build"]
                self.assertEqual(self.run_build(*arguments), arguments)

    def test_leaves_distribution_configurations_unchanged(self) -> None:
        for configuration in ("Release", "Nightly"):
            with self.subTest(configuration=configuration):
                arguments = ["-configuration", configuration, "build"]
                self.assertEqual(self.run_build(*arguments), arguments)
