"""Release metadata, artifact integrity, and draft-first publication checks.

The GitHub fake stores uploaded bytes and implements CLI responses; these tests
do not need GitHub credentials and cannot publish a release.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release


SHA = "a" * 40
REPO = "example/OpenRay"


def write_package(directory: Path, version="1.2.3", build=42, sha=SHA):
    directory.mkdir()
    (directory / "READY-FOR-SMOKE-TEST.txt").write_text("Production packaging checks passed.\n")
    (directory / "build-info.txt").write_text(
        f"OpenRay {version} ({build})\nSource commit: {sha}\nLocal preview: 0\n"
    )
    lines = []
    for extension in ("dmg", "zip"):
        name = f"OpenRay-{version}.{extension}"
        content = f"test production package {extension}".encode()
        (directory / name).write_bytes(content)
        lines.append(f"{hashlib.sha256(content).hexdigest()}  {name}\n")
    (directory / "SHA256SUMS").write_text("".join(lines))


class FakeGitHub:
    """Stateful gh adapter, including remote bytes and publication races."""

    def __init__(self, directory, *, exists=False, published=False, tag="v1.2.3", prerelease=False):
        self.directory = directory
        self.tag = tag
        self.sha = SHA
        self.item = self.record(41, tag, draft=not published, prerelease=prerelease) if exists else None
        self.other_releases = []
        self.remote_bytes = {}
        self.calls = []
        self.tag_checks = 0
        self.move_tag_on_check = None
        self.publish_on_current_check = None
        self.current_checks = 0
        self.fail_upload = None
        self.corrupt_download = None
        self.hidden_draft_reads = 0

    @staticmethod
    def record(identifier, tag, *, draft=False, prerelease=False):
        return {"id": identifier, "tag_name": tag, "draft": draft, "prerelease": prerelease}

    def seed_assets(self, names=release.RELEASE_ASSETS):
        self.remote_bytes.update({name: (self.directory / name).read_bytes() for name in names})

    def __call__(self, argv, *, check, capture_output, text):
        assert check is False and capture_output is True and text is True
        self.calls.append(argv)
        result = self.execute(argv)
        if isinstance(result, subprocess.CompletedProcess):
            return result
        return subprocess.CompletedProcess(argv, 0, json.dumps(result) if not isinstance(result, str) else result, "")

    def execute(self, argv):
        assert argv[0] == "gh"
        if argv[1] == "api":
            endpoint = argv[2].removeprefix(f"repos/{REPO}/")
            if endpoint.startswith("commits/"):
                assert endpoint == f"commits/{quote('refs/tags/' + self.tag, safe='')}"
                self.tag_checks += 1
                if self.tag_checks == self.move_tag_on_check:
                    self.sha = "b" * 40
                return {"sha": self.sha}
            if endpoint == "releases?per_page=100":
                assert "--paginate" in argv and "--slurp" in argv
                # Separate pages ensure latest selection is not based on page one.
                if self.item and self.item["draft"] and self.hidden_draft_reads:
                    self.hidden_draft_reads -= 1
                    return [[], self.other_releases]
                return [[self.item] if self.item else [], self.other_releases]
            if endpoint == "releases/41":
                self.current_checks += 1
                if self.current_checks == self.publish_on_current_check:
                    self.item["draft"] = False
                return dict(self.item)
            if endpoint == "releases/41/assets?per_page=100":
                assert "--paginate" in argv and "--slurp" in argv
                return [[{"name": name, "size": len(content)} for name, content in self.remote_bytes.items()]]
            raise AssertionError(f"Unexpected API call: {argv}")
        assert argv[1] == "release"
        action = argv[2]
        assert argv[3] == self.tag
        assert argv[argv.index("--repo") + 1] == REPO
        if action == "create":
            assert self.item is None
            assert "--draft" in argv and "--verify-tag" in argv and "--latest=false" in argv
            self.item = self.record(41, self.tag, draft=True, prerelease="--prerelease=true" in argv)
        elif action == "upload":
            assert self.item["draft"], "Published releases must never be modified."
            path = Path(argv[4])
            if path.name == self.fail_upload:
                return subprocess.CompletedProcess(argv, 1, "", "simulated upload interruption")
            assert ("--clobber" in argv) == (path.name in self.remote_bytes)
            self.remote_bytes[path.name] = path.read_bytes()
        elif action == "download":
            destination = Path(argv[argv.index("--dir") + 1])
            for i, arg in enumerate(argv):
                if arg == "--pattern":
                    name = argv[i + 1]
                    content = self.remote_bytes[name]
                    if name == self.corrupt_download:
                        content += b"corrupted"
                    (destination / name).write_bytes(content)
        elif action == "edit":
            assert self.item["draft"], "Published release metadata must never be edited."
            assert set(self.remote_bytes) == set(release.RELEASE_ASSETS)
            assert "--verify-tag" in argv and "--draft=false" in argv
            self.item["draft"] = False
            self.item["prerelease"] = "--prerelease=true" in argv
        else:
            raise AssertionError(f"Unexpected release call: {argv}")
        return ""

    def mutations(self, action=None):
        return [
            command for command in self.calls
            if command[1:3] in (["release", "create"], ["release", "upload"], ["release", "edit"])
            and (action is None or command[2] == action)
        ]


class VersionTests(unittest.TestCase):
    def test_canonical_semver(self):
        for tag, prerelease in (
            ("v0.0.0", False), ("v12.34.56", False), ("v1.2.3-rc.1", True),
            ("v1.2.3-alpha.0", True), ("v1.2.3+build.001", False), ("v1.2.3-rc.1+ci.42", True),
        ):
            with self.subTest(tag=tag):
                version = release.parse_tag(tag)
                self.assertEqual(version.version, tag[1:])
                self.assertEqual(version.prerelease, prerelease)

    def test_invalid_versions_are_rejected(self):
        for tag in ("1.2.3", "v1.2", "v01.2.3", "v1.02.3", "v1.2.03", "v1.2.3-01", "v1.2.3-rc.01",
                    "v1.2.3-", "v1.2.3+", "v1.2.3-rc..1", "v1.2.3\n", "v1.2.3\nprerelease=false", "latest"):
            with self.subTest(tag=tag), self.assertRaises(release.ReleaseError):
                release.parse_tag(tag)

    def test_build_number(self):
        self.assertEqual(release.parse_build_number("42"), 42)
        for value in ("0", "-1", "01", "1.2", "1\n", "", " 1"):
            with self.subTest(value=value), self.assertRaises(release.ReleaseError):
                release.parse_build_number(value)

    def test_cli_metadata_outputs(self):
        result = subprocess.run(
            [sys.executable, str(Path(release.__file__)), "metadata", "--tag", "v1.2.3-rc.1", "--build-number", "42"],
            check=True, capture_output=True, text=True,
        )
        self.assertEqual(result.stdout, "tag=v1.2.3-rc.1\nversion=1.2.3-rc.1\nmarketing_version=1.2.3\nprerelease=true\n")

    def test_latest_uses_numeric_semver_and_ignores_drafts_and_prereleases(self):
        releases = [FakeGitHub.record(1, "v1.9.0"), FakeGitHub.record(2, "v2.0.0", draft=True),
                    FakeGitHub.record(3, "v4.0.0-rc.1", prerelease=True), FakeGitHub.record(4, "latest")]
        self.assertTrue(release.should_be_latest(release.parse_tag("v1.10.0"), releases))
        self.assertFalse(release.should_be_latest(release.parse_tag("v1.8.1"), releases))
        self.assertFalse(release.should_be_latest(release.parse_tag("v3.0.0-rc.1"), releases))
        self.assertTrue(release.should_be_latest(release.parse_tag("v1.9.0+ci.42"), releases))


class ReleaseFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.package = self.root / "package"
        self.output = self.root / "release"
        self.version = release.parse_tag("v1.2.3")
        write_package(self.package)

    def stage(self, **kwargs):
        release.stage(self.package, self.output, kwargs.get("version", self.version), kwargs.get("build", 42), kwargs.get("sha", SHA))


class ArtifactTests(ReleaseFixture):
    def test_stage_preserves_verified_bytes_and_records_provenance(self):
        self.stage(version=release.parse_tag("v1.2.3-rc.1"))
        manifest = json.loads((self.output / "release.json").read_text())
        self.assertEqual(manifest["tag"], "v1.2.3-rc.1")
        self.assertEqual(manifest["version"], "1.2.3-rc.1")
        self.assertEqual(manifest["marketing_version"], "1.2.3")
        self.assertEqual(manifest["build_number"], 42)
        self.assertEqual(manifest["commit"], SHA)
        self.assertEqual(manifest["architecture"], "arm64")
        self.assertEqual(manifest["minimum_macos"], "26.0")
        for extension in ("dmg", "zip"):
            self.assertEqual((self.package / f"OpenRay-1.2.3.{extension}").read_bytes(),
                             (self.output / f"OpenRay-macos-arm64.{extension}").read_bytes())
        self.assertEqual(set(release.validate_staged(self.output, release.parse_tag("v1.2.3-rc.1"), SHA)), set(release.RELEASE_ASSETS))

    def test_stage_requires_production_marker(self):
        (self.package / "READY-FOR-SMOKE-TEST.txt").unlink()
        with self.assertRaises(release.ReleaseError):
            self.stage()
        self.assertFalse(self.output.exists())

    def test_preview_marker_and_filenames_are_rejected(self):
        for filename in ("PREVIEW-ONLY.txt", "OpenRay-1.2.3-local-preview.dmg", "staging/LOCAL PREVIEW ONLY.txt"):
            with self.subTest(filename=filename):
                path = self.package / filename
                path.parent.mkdir(exist_ok=True)
                path.write_text("preview")
                with self.assertRaises(release.ReleaseError):
                    self.stage()
                path.unlink()

    def test_package_checksum_mismatch_is_rejected(self):
        (self.package / "OpenRay-1.2.3.zip").write_bytes(b"modified after packaging")
        with self.assertRaisesRegex(release.ReleaseError, "Checksum mismatch"):
            self.stage()

    def test_source_manifest_cannot_reference_other_files(self):
        with (self.package / "SHA256SUMS").open("a") as stream:
            stream.write(f"{'a' * 64}  ../secret\n")
        with self.assertRaises(release.ReleaseError):
            self.stage()

    def test_duplicate_checksums_are_rejected(self):
        path = self.package / "SHA256SUMS"
        path.write_text(path.read_text() * 2)
        with self.assertRaisesRegex(release.ReleaseError, "Duplicate checksum"):
            self.stage()

    def test_package_provenance_must_match(self):
        for kwargs in ({"version": release.parse_tag("v1.2.4")}, {"build": 43}, {"sha": "b" * 40}):
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(release.ReleaseError, "build-info"):
                self.stage(**kwargs)

    def test_existing_output_is_not_replaced(self):
        self.output.mkdir()
        sentinel = self.output / "keep.txt"
        sentinel.write_text("keep")
        with self.assertRaisesRegex(release.ReleaseError, "already exists"):
            self.stage()
        self.assertEqual(sentinel.read_text(), "keep")

    def test_symlink_package_assets_are_rejected(self):
        path = self.package / "OpenRay-1.2.3.zip"
        saved = self.root / "elsewhere.zip"
        path.rename(saved)
        path.symlink_to(saved)
        with self.assertRaisesRegex(release.ReleaseError, "regular file"):
            self.stage()

    def test_modified_release_json_is_rejected(self):
        self.stage()
        (self.output / "release.json").write_text("{}")
        with self.assertRaisesRegex(release.ReleaseError, "Checksum mismatch"):
            release.validate_staged(self.output, self.version, SHA)

    def test_wrong_requested_provenance_is_rejected(self):
        self.stage()
        with self.assertRaisesRegex(release.ReleaseError, "provenance"):
            release.validate_staged(self.output, release.parse_tag("v1.2.3-rc.1"), SHA)

    def test_extra_artifacts_are_rejected(self):
        self.stage()
        (self.output / "signing.p12").write_text("must never upload")
        with self.assertRaisesRegex(release.ReleaseError, "exactly"):
            release.validate_staged(self.output, self.version, SHA)


class PublishTests(ReleaseFixture):
    def setUp(self):
        super().setUp()
        self.stage()

    def publish(self, fake, public=True, version=None):
        return release.publish(self.output, REPO, version or self.version, SHA, public=public, run=fake)

    def test_create_upload_verify_publish_in_order(self):
        fake = FakeGitHub(self.output)
        self.assertIn("latest=true", self.publish(fake))
        mutations = fake.mutations()
        self.assertEqual([command[2] for command in mutations], ["create", "upload", "upload", "upload", "upload", "edit"])
        self.assertEqual(set(fake.remote_bytes), set(release.RELEASE_ASSETS))
        edit_index = next(i for i, command in enumerate(fake.calls) if command[1:3] == ["release", "edit"])
        self.assertTrue(any(command[1:3] == ["release", "download"] for command in fake.calls[:edit_index]))

    def test_manual_mode_stops_at_verified_draft(self):
        fake = FakeGitHub(self.output)
        self.assertIn("Draft ready", self.publish(fake, public=False))
        self.assertTrue(fake.item["draft"])
        self.assertEqual(fake.mutations("edit"), [])

    def test_new_draft_lookup_retries_until_visible_without_creating_again(self):
        fake = FakeGitHub(self.output)
        fake.hidden_draft_reads = 2
        with patch("time.sleep") as sleep:
            self.assertIn("Published verified release", self.publish(fake))
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(len(fake.mutations("create")), 1)
        self.assertEqual(len(fake.mutations("upload")), 4)
        self.assertEqual(len(fake.mutations("edit")), 1)

    def test_new_draft_lookup_stops_after_bounded_retries_without_uploading(self):
        fake = FakeGitHub(self.output)
        fake.hidden_draft_reads = 100
        with patch("time.sleep") as sleep:
            with self.assertRaisesRegex(release.ReleaseError, "Could not locate the newly created draft release"):
                self.publish(fake)
        self.assertEqual(sleep.call_count, 4)
        self.assertTrue(all(call.args == (2,) for call in sleep.call_args_list))
        self.assertEqual(fake.hidden_draft_reads, 95)
        self.assertEqual(len(fake.mutations("create")), 1)
        self.assertEqual(fake.mutations("upload"), [])
        self.assertEqual(fake.mutations("edit"), [])
        self.assertTrue(fake.item["draft"])

    def test_backport_checks_all_release_pages(self):
        fake = FakeGitHub(self.output)
        fake.other_releases = [fake.record(9, "v1.10.0")]
        self.assertIn("latest=false", self.publish(fake))
        self.assertIn("--latest=false", fake.mutations("edit")[0])

    def test_prerelease_is_never_latest(self):
        import shutil
        shutil.rmtree(self.output)
        version = release.parse_tag("v1.2.3-rc.1")
        self.stage(version=version)
        fake = FakeGitHub(self.output, tag=version.tag, prerelease=True)
        self.assertIn("latest=false", self.publish(fake, version=version))
        self.assertTrue(fake.item["prerelease"])
        self.assertIn("--prerelease=true", fake.mutations("edit")[0])

    def test_initial_tag_mismatch_prevents_all_writes(self):
        fake = FakeGitHub(self.output)
        fake.sha = "b" * 40
        with self.assertRaisesRegex(release.ReleaseError, "does not resolve"):
            self.publish(fake)
        self.assertEqual(fake.mutations(), [])

    def test_commit_check_uses_qualified_tag_ref(self):
        fake = FakeGitHub(self.output)
        self.publish(fake, public=False)
        checks = [command for command in fake.calls if command[1] == "api" and "/commits/" in command[2]]
        self.assertTrue(checks)
        self.assertTrue(all(command[2].endswith("/commits/refs%2Ftags%2Fv1.2.3") for command in checks))

    def test_tag_move_before_final_publication_leaves_draft(self):
        fake = FakeGitHub(self.output)
        # Initial + before create + four uploads + post verification + prepublish.
        fake.move_tag_on_check = 8
        with self.assertRaisesRegex(release.ReleaseError, "does not resolve"):
            self.publish(fake)
        self.assertEqual(fake.mutations("edit"), [])
        self.assertTrue(fake.item["draft"])

    def test_identical_published_release_is_noop(self):
        fake = FakeGitHub(self.output, exists=True, published=True)
        fake.seed_assets()
        self.assertIn("no changes made", self.publish(fake))
        self.assertEqual(fake.mutations(), [])

    def test_different_published_asset_is_never_replaced(self):
        fake = FakeGitHub(self.output, exists=True, published=True)
        fake.seed_assets()
        fake.remote_bytes[release.PACKAGE_ASSETS[0]] = b"a different release"
        with self.assertRaisesRegex(release.ReleaseError, "Published assets are never replaced"):
            self.publish(fake)
        self.assertEqual(fake.mutations(), [])

    def test_incomplete_published_release_is_not_repaired(self):
        fake = FakeGitHub(self.output, exists=True, published=True)
        fake.seed_assets(release.PACKAGE_ASSETS)
        with self.assertRaisesRegex(release.ReleaseError, "asset names"):
            self.publish(fake)
        self.assertEqual(fake.mutations(), [])

    def test_interrupted_upload_can_resume_matching_draft(self):
        fake = FakeGitHub(self.output)
        fake.fail_upload = "SHA256SUMS"
        with self.assertRaisesRegex(release.ReleaseError, "interruption"):
            self.publish(fake)
        self.assertTrue(fake.item["draft"])
        self.assertEqual(set(fake.remote_bytes), set(release.PACKAGE_ASSETS))
        fake.calls.clear()
        fake.fail_upload = None
        self.publish(fake)
        self.assertEqual([Path(command[4]).name for command in fake.mutations("upload")], ["SHA256SUMS", "release.json"])

    def test_partial_draft_with_changed_bytes_can_resume(self):
        fake = FakeGitHub(self.output, exists=True)
        fake.seed_assets((release.PACKAGE_ASSETS[0],))
        fake.remote_bytes[release.PACKAGE_ASSETS[0]] = b"earlier signing timestamp"
        self.publish(fake)
        self.assertEqual(fake.remote_bytes[release.PACKAGE_ASSETS[0]], (self.output / release.PACKAGE_ASSETS[0]).read_bytes())
        self.assertIn("--clobber", fake.mutations("upload")[0])

    def test_same_source_draft_can_be_refreshed_from_new_build(self):
        fake = FakeGitHub(self.output, exists=True)
        fake.seed_assets()
        manifest = json.loads(fake.remote_bytes["release.json"])
        manifest["build_number"] = 41
        fake.remote_bytes["release.json"] = json.dumps(manifest).encode()
        fake.remote_bytes[release.PACKAGE_ASSETS[0]] = b"earlier signing timestamp"
        fake.remote_bytes["SHA256SUMS"] = b"previous checksums"
        self.publish(fake)
        for name in release.RELEASE_ASSETS:
            self.assertEqual(fake.remote_bytes[name], (self.output / name).read_bytes())
        self.assertEqual(len(fake.mutations("upload")), 3)
        self.assertTrue(all("--clobber" in command for command in fake.mutations("upload")))

    def test_draft_with_different_source_provenance_is_preserved(self):
        fake = FakeGitHub(self.output, exists=True)
        fake.seed_assets()
        manifest = json.loads(fake.remote_bytes["release.json"])
        manifest["commit"] = "b" * 40
        fake.remote_bytes["release.json"] = json.dumps(manifest).encode()
        with self.assertRaisesRegex(release.ReleaseError, "draft provenance differs"):
            self.publish(fake)
        self.assertEqual(fake.mutations(), [])

    def test_download_digest_failure_keeps_release_draft(self):
        fake = FakeGitHub(self.output)
        fake.corrupt_download = "release.json"
        with self.assertRaisesRegex(release.ReleaseError, "Remote asset differs"):
            self.publish(fake)
        self.assertTrue(fake.item["draft"])
        self.assertEqual(fake.mutations("edit"), [])

    def test_external_publication_stops_uploads(self):
        fake = FakeGitHub(self.output, exists=True)
        fake.publish_on_current_check = 2
        with self.assertRaisesRegex(release.ReleaseError, "published during upload"):
            self.publish(fake)
        self.assertEqual(fake.mutations(), [])

    def test_unexpected_remote_asset_blocks_publication(self):
        fake = FakeGitHub(self.output, exists=True)
        fake.remote_bytes["unexpected.txt"] = b"not a release artifact"
        with self.assertRaisesRegex(release.ReleaseError, "asset names"):
            self.publish(fake)
        self.assertEqual(fake.mutations(), [])


if __name__ == "__main__":
    unittest.main()
