#!/usr/bin/env python3
"""Exercise CI credential lifecycle with fake tools; never touch a real keychain."""

import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("ci-signing.sh")
IDENTITY = "Developer ID Application: Example Developer (EXAMPLE123)"
OTHER_IDENTITY = "Developer ID Application: Another Developer (OTHER12345)"
MOCK_TOOL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["MOCK_CALLS"], "a") as calls:
    calls.write(json.dumps([tool, *args]) + "\n")
if tool == "uname":
    print("Darwin")
elif tool == "openssl":
    if args[0] == "rand":
        print("a" * 64)
    elif args[0] == "pkey":
        assert Path(args[args.index("-in") + 1]).read_text() == "fixture-notary-private-key"
    else:
        sys.exit(99)
elif tool == "security":
    action = args[0]
    # Every security invocation must name a keychain owned by this fixture.
    keychain = next((Path(arg) for arg in args if arg.endswith(".keychain-db")), None)
    assert keychain is not None
    assert keychain.parent.parent == Path(os.environ["RUNNER_TEMP"])
    assert keychain.parent.name.startswith("openray-signing.")
    if action == "create-keychain":
        keychain.write_text("fixture-encrypted-keychain")
    elif action == "delete-keychain":
        keychain.unlink()
    elif action == "find-identity":
        names = os.environ.get("MOCK_IDENTITIES", "Developer ID Application: Example Developer (EXAMPLE123)").split("|")
        for number, name in enumerate(names, 1):
            print(f'  {number}) {number:040X} "{name}"')
        print(f"     {len(names)} valid identities found")
    elif action == "import":
        assert Path(args[1]).read_text() == "fixture-certificate-and-private-key"
        assert "-A" not in args
        assert args[args.index("-T") + 1] == "/usr/bin/codesign"
    else:
        assert action in {"set-keychain-settings", "unlock-keychain", "set-key-partition-list"}
    if os.environ.get("MOCK_FAIL") == action:
        print("fixture-certificate-password fixture-notary-private-key", file=sys.stderr)
        sys.exit(1)
elif tool == "xcrun":
    assert args[:2] == ["notarytool", "store-credentials"]
    keychain = Path(args[args.index("--keychain") + 1])
    assert keychain.is_file()
    assert keychain.parent.parent == Path(os.environ["RUNNER_TEMP"])
    assert Path(args[args.index("--key") + 1]).read_text() == "fixture-notary-private-key"
    assert "--no-validate" not in args
    if os.environ.get("MOCK_FAIL") == "notarytool":
        print("fixture-notary-private-key", file=sys.stderr)
        sys.exit(1)
else:
    sys.exit(99)
'''


class SigningLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="openray-signing-tests-")
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name).resolve()
        self.runner = self.root / "runner temp with spaces"
        self.runner.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("security", "xcrun", "openssl", "uname"):
            mock = self.bin / name
            mock.write_text(MOCK_TOOL)
            mock.chmod(0o755)
        self.github_env = self.root / "github-env"
        self.github_env.touch()
        self.calls_path = self.root / "calls.jsonl"
        self.env = {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "GITHUB_ACTIONS": "true",
            "RUNNER_ENVIRONMENT": "github-hosted",
            "RUNNER_TEMP": str(self.runner),
            "GITHUB_ENV": str(self.github_env),
            "MOCK_CALLS": str(self.calls_path),
            "APPLE_CERTIFICATE_P12_BASE64": base64.b64encode(b"fixture-certificate-and-private-key").decode(),
            "APPLE_CERTIFICATE_PASSWORD": "fixture-certificate-password",
            "APPLE_NOTARY_KEY_P8_BASE64": base64.b64encode(b"fixture-notary-private-key").decode(),
            "APPLE_NOTARY_KEY_ID": "EXAMPLE1234",
            "APPLE_NOTARY_ISSUER_ID": "00000000-0000-0000-0000-000000000000",
        }

    def run_script(self, command="setup"):
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT), command], env=self.env,
            text=True, capture_output=True, check=False,
        )
        for secret in ("fixture-certificate-password", "fixture-notary-private-key", "fixture-certificate-and-private-key"):
            self.assertNotIn(secret, result.stdout + result.stderr)
        return result

    def calls(self):
        if not self.calls_path.exists():
            return []
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()]

    def exported(self):
        return dict(line.split("=", 1) for line in self.github_env.read_text().splitlines())

    def test_setup_cleanup_preserves_unrelated_files_and_exports_only_handles(self):
        unrelated = self.runner / "existing.keychain-db"
        unrelated.write_text("leave this keychain alone")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        exported = self.exported()
        self.assertEqual(exported["OPENRAY_SIGNING_IDENTITY"], IDENTITY)
        directory = Path(exported["OPENRAY_SIGNING_DIRECTORY"])
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual({path.name for path in directory.iterdir()}, {".openray-ci-signing", "release.keychain-db"})
        self.assertEqual(exported["OPENRAY_SIGNING_KEYCHAIN"], exported["OPENRAY_NOTARY_KEYCHAIN"])
        self.assertFalse(any(call[1] in {"list-keychains", "default-keychain"} for call in self.calls() if call[0] == "security"))
        self.assertEqual(set(exported), {
            "OPENRAY_SIGNING_IDENTITY", "OPENRAY_SIGNING_KEYCHAIN", "OPENRAY_NOTARY_PROFILE",
            "OPENRAY_NOTARY_KEYCHAIN", "OPENRAY_SIGNING_DIRECTORY",
        })
        self.env.update(exported)
        result = self.run_script("cleanup")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(directory.exists())
        self.assertEqual(unrelated.read_text(), "leave this keychain alone")
        self.assertEqual(self.run_script("cleanup").returncode, 0)

    def test_missing_secret_fails_before_keychain_changes(self):
        del self.env["APPLE_CERTIFICATE_PASSWORD"]
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("APPLE_CERTIFICATE_PASSWORD", result.stderr)
        self.assertFalse(any(call[0] == "security" for call in self.calls()))
        self.assertEqual(list(self.runner.iterdir()), [])

    def test_invalid_base64_is_removed_without_import(self):
        self.env["APPLE_CERTIFICATE_P12_BASE64"] = "not base64!"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.runner.iterdir()), [])
        self.assertFalse(any(call[0] == "security" for call in self.calls()))

    def test_failed_import_and_notarization_remove_all_temporary_credentials(self):
        for failure in ("create-keychain", "import", "notarytool"):
            with self.subTest(failure=failure):
                self.env["MOCK_FAIL"] = failure
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(self.runner.iterdir()), [])
                self.assertEqual(self.github_env.read_text(), "")
                self.assertTrue(any(call[:2] == ["security", "delete-keychain"] for call in self.calls()))

    def test_apple_development_identity_cannot_be_used(self):
        self.env["MOCK_IDENTITIES"] = "Apple Development: Example Developer (EXAMPLE123)"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Developer ID Application", result.stderr)
        self.assertEqual(list(self.runner.iterdir()), [])

    def test_ambiguous_identity_requires_explicit_selection(self):
        self.env["MOCK_IDENTITIES"] = f"{IDENTITY}|{OTHER_IDENTITY}"
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(list(self.runner.iterdir()), [])
        self.env["OPENRAY_SIGNING_IDENTITY"] = OTHER_IDENTITY
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.exported()["OPENRAY_SIGNING_IDENTITY"], OTHER_IDENTITY)
        self.env.update(self.exported())
        self.assertEqual(self.run_script("cleanup").returncode, 0)

    def test_cleanup_refuses_unowned_directory(self):
        unrelated = self.runner / "openray-signing.12345678"
        unrelated.mkdir()
        certificate = unrelated / "certificate.p12"
        certificate.write_text("unrelated private material")
        self.env["OPENRAY_SIGNING_DIRECTORY"] = str(unrelated)
        self.assertNotEqual(self.run_script("cleanup").returncode, 0)
        self.assertEqual(certificate.read_text(), "unrelated private material")
        self.assertEqual(self.calls(), [])

    def test_setup_refuses_local_execution(self):
        self.env.pop("GITHUB_ACTIONS")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertEqual(list(self.runner.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
