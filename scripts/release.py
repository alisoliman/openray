#!/usr/bin/env python3
"""Stage verified macOS packages and publish GitHub releases, draft first.

This does not sign or notarize software. Production packaging performs those
checks; staging requires its completion marker, provenance, and checksums.
Only the Python standard library and the authenticated GitHub CLI are used.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Callable
from urllib.parse import quote


PACKAGE_ASSETS = ("OpenRay-macos-arm64.dmg", "OpenRay-macos-arm64.zip")
RELEASE_ASSETS = (*PACKAGE_ASSETS, "SHA256SUMS", "release.json")
SEMVER = re.compile(
    r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
)


class ReleaseError(ValueError):
    """A release cannot safely proceed."""


@dataclass(frozen=True)
class Version:
    tag: str
    core: tuple[int, int, int]
    prerelease: bool

    @property
    def version(self) -> str:
        return self.tag[1:]

    @property
    def marketing_version(self) -> str:
        return ".".join(map(str, self.core))


def parse_tag(tag: str) -> Version:
    match = SEMVER.fullmatch(tag)
    if match is None:
        raise ReleaseError("Tag must be canonical SemVer with a v prefix, e.g. v1.2.3 or v1.2.3-rc.1.")
    prerelease = match.group(4)
    if prerelease and any(part.isdigit() and len(part) > 1 and part[0] == "0" for part in prerelease.split(".")):
        raise ReleaseError("Numeric prerelease identifiers cannot have leading zeroes.")
    return Version(tag, tuple(int(match.group(i)) for i in (1, 2, 3)), prerelease is not None)


def parse_build_number(value: str) -> int:
    if re.fullmatch(r"[1-9][0-9]*", value) is None:
        raise ReleaseError("Build number must be a positive integer without leading zeroes.")
    return int(value)


def validate_sha(sha: str) -> None:
    if re.fullmatch(r"[0-9a-f]{40}", sha) is None:
        raise ReleaseError("Source SHA must be a full 40-character lowercase commit SHA.")


def regular_file(path: Path) -> Path:
    if path.is_symlink() or not path.is_file():
        raise ReleaseError(f"Expected a regular file: {path}")
    return path


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with regular_file(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def read_checksums(path: Path, expected_names: set[str]) -> dict[str, str]:
    values = {}
    for line in regular_file(path).read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64}) [ *]([^/\\]+)", line)
        if match is None or match.group(2) not in expected_names:
            raise ReleaseError(f"Unexpected checksum entry in {path}: {line!r}")
        checksum, name = match.groups()
        if name in values:
            raise ReleaseError(f"Duplicate checksum for {name}.")
        values[name] = checksum
    if set(values) != expected_names:
        raise ReleaseError(f"Checksum manifest must contain exactly: {', '.join(sorted(expected_names))}")
    return values


def verify_checksums(directory: Path, checksums: dict[str, str]) -> None:
    for name, expected in checksums.items():
        if digest(directory / name) != expected:
            raise ReleaseError(f"Checksum mismatch: {name}")


def stage(package_dir: Path, output: Path, version: Version, build_number: int, sha: str) -> None:
    validate_sha(sha)
    if output.exists() or output.is_symlink():
        raise ReleaseError(f"Output already exists: {output}")
    regular_file(package_dir / "READY-FOR-SMOKE-TEST.txt")
    if not (package_dir / "READY-FOR-SMOKE-TEST.txt").read_text(encoding="utf-8").strip():
        raise ReleaseError("Production packaging completion marker is empty.")
    if any("preview" in entry.name.lower() for entry in package_dir.iterdir()) or (
        package_dir / "staging" / "LOCAL PREVIEW ONLY.txt"
    ).exists():
        raise ReleaseError("Local preview packages cannot be released.")
    build_info = regular_file(package_dir / "build-info.txt").read_text(encoding="utf-8").splitlines()
    expected_info = (
        f"OpenRay {version.marketing_version} ({build_number})",
        f"Source commit: {sha}",
        "Local preview: 0",
    )
    if any(build_info.count(line) != 1 for line in expected_info):
        raise ReleaseError("Package build-info.txt does not match the requested version, build, commit, or production mode.")
    source_names = {f"OpenRay-{version.marketing_version}.{extension}" for extension in ("dmg", "zip")}
    checksums = read_checksums(package_dir / "SHA256SUMS", source_names)
    verify_checksums(package_dir, checksums)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".openray-release-", dir=output.parent) as temporary:
        staged = Path(temporary) / "assets"
        staged.mkdir()
        artifacts = {}
        for name in PACKAGE_ASSETS:
            source_name = f"OpenRay-{version.marketing_version}{Path(name).suffix}"
            shutil.copyfile(package_dir / source_name, staged / name)
            checksum = digest(staged / name)
            if checksum != checksums[source_name]:
                raise ReleaseError(f"Package changed during staging: {source_name}")
            artifacts[name] = {"sha256": checksum, "size": (staged / name).stat().st_size}
        manifest = {
            "schema_version": 1,
            "name": "OpenRay",
            "tag": version.tag,
            "version": version.version,
            "marketing_version": version.marketing_version,
            "build_number": build_number,
            "commit": sha,
            "architecture": "arm64",
            "minimum_macos": "26.0",
            "artifacts": artifacts,
        }
        (staged / "release.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        checksum_names = (*PACKAGE_ASSETS, "release.json")
        (staged / "SHA256SUMS").write_text(
            "".join(f"{digest(staged / name)}  {name}\n" for name in checksum_names), encoding="utf-8"
        )
        staged.rename(output)


def validate_staged(directory: Path, version: Version, sha: str) -> dict[str, str]:
    validate_sha(sha)
    if not directory.is_dir() or {path.name for path in directory.iterdir()} != set(RELEASE_ASSETS):
        raise ReleaseError("Release directory must contain exactly the DMG, ZIP, SHA256SUMS, and release.json.")
    checksums = read_checksums(directory / "SHA256SUMS", {*PACKAGE_ASSETS, "release.json"})
    verify_checksums(directory, checksums)
    manifest = json.loads(regular_file(directory / "release.json").read_text(encoding="utf-8"))
    expected = {
        "schema_version": 1, "name": "OpenRay", "tag": version.tag, "version": version.version,
        "marketing_version": version.marketing_version, "commit": sha,
        "architecture": "arm64", "minimum_macos": "26.0",
    }
    if not isinstance(manifest, dict) or any(manifest.get(key) != value for key, value in expected.items()):
        raise ReleaseError("Release manifest provenance does not match this release.")
    if type(manifest.get("build_number")) is not int or manifest["build_number"] <= 0:
        raise ReleaseError("Release manifest build number must be a positive integer.")
    expected_artifacts = {
        name: {"sha256": checksums[name], "size": (directory / name).stat().st_size} for name in PACKAGE_ASSETS
    }
    if manifest.get("artifacts") != expected_artifacts:
        raise ReleaseError("Release manifest artifact hashes or sizes are incorrect.")
    return {name: digest(directory / name) for name in RELEASE_ASSETS}


def should_be_latest(candidate: Version, releases: list[dict]) -> bool:
    if candidate.prerelease:
        return False
    stable = []
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        try:
            version = parse_tag(release["tag_name"])
        except (ReleaseError, KeyError, TypeError):
            continue
        if not version.prerelease:
            stable.append(version.core)
    return not stable or candidate.core >= max(stable)


class GitHub:
    def __init__(self, repo: str, run: Callable = subprocess.run):
        if re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", repo) is None or repo.split("/")[-1] in (".", ".."):
            raise ReleaseError("Repository must be OWNER/REPO on GitHub.")
        self.repo = repo
        self.run = run

    def call(self, *args: str) -> str:
        result = self.run(["gh", *args], check=False, capture_output=True, text=True)
        if result.returncode:
            raise ReleaseError(f"GitHub CLI failed: {result.stderr.strip()}")
        return result.stdout

    def api(self, endpoint: str, *args: str):
        return json.loads(self.call("api", f"repos/{self.repo}/{endpoint}", *args))

    def paginated(self, endpoint: str) -> list[dict]:
        pages = self.api(endpoint, "--paginate", "--slurp")
        if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
            raise ReleaseError("Unexpected paginated GitHub API response.")
        return [item for page in pages for item in page]

    def releases(self) -> list[dict]:
        return self.paginated("releases?per_page=100")

    def assert_tag(self, tag: str, sha: str) -> None:
        # An unqualified name can resolve a branch with the same name. Require
        # the actual tag ref, including for annotated tags that peel to a commit.
        commit = self.api(f"commits/{quote('refs/tags/' + tag, safe='')}")
        if not isinstance(commit, dict) or commit.get("sha") != sha:
            raise ReleaseError(f"Remote tag {tag} does not resolve to the requested commit. No tag will be created or moved.")

    def current(self, release_id: int, tag: str) -> dict:
        release = self.api(f"releases/{release_id}")
        if release.get("id") != release_id or release.get("tag_name") != tag:
            raise ReleaseError("The remote release changed identity during publication.")
        if type(release.get("draft")) is not bool:
            raise ReleaseError("The remote release has no valid draft state.")
        return release

    def assets(self, release_id: int) -> list[dict]:
        return self.paginated(f"releases/{release_id}/assets?per_page=100")

    def verify_assets(
        self, release_id: int, tag: str, hashes: dict[str, str], *, complete: bool,
        draft_provenance: tuple[str, str] | None = None,
    ) -> tuple[set[str], set[str]]:
        assets = self.assets(release_id)
        names = [asset.get("name") for asset in assets]
        if len(set(names)) != len(names) or set(names) - set(hashes) or (complete and set(names) != set(hashes)):
            raise ReleaseError("Remote release asset names differ from the exact expected release assets.")
        changed = set()
        if names:
            with tempfile.TemporaryDirectory(prefix="openray-release-download-") as temporary:
                args = ["release", "download", tag, "--repo", self.repo, "--dir", temporary]
                for name in sorted(names):
                    args.extend(("--pattern", name))
                self.call(*args)
                downloaded = Path(temporary)
                if {path.name for path in downloaded.iterdir()} != set(names):
                    raise ReleaseError("Downloaded asset names differ from the GitHub asset listing.")
                if draft_provenance is not None and "release.json" in names:
                    manifest = json.loads(regular_file(downloaded / "release.json").read_text(encoding="utf-8"))
                    if not isinstance(manifest, dict) or (manifest.get("tag"), manifest.get("commit")) != draft_provenance:
                        raise ReleaseError("Existing draft provenance differs from this tag or source commit; refusing replacement.")
                for name in names:
                    if digest(downloaded / name) != hashes[name]:
                        if draft_provenance is None:
                            raise ReleaseError(f"Remote asset differs from the local release: {name}. Published assets are never replaced.")
                        changed.add(name)
        return set(names), changed


def publish(directory: Path, repo: str, version: Version, sha: str, *, public: bool = False, run: Callable = subprocess.run) -> str:
    hashes = validate_staged(directory, version, sha)
    github = GitHub(repo, run)
    github.assert_tag(version.tag, sha)
    matching = [release for release in github.releases() if release.get("tag_name") == version.tag]
    if len(matching) > 1:
        raise ReleaseError("Multiple remote releases use this tag.")
    if not matching:
        github.assert_tag(version.tag, sha)
        github.call(
            "release", "create", version.tag, "--repo", repo, "--verify-tag", "--target", sha,
            "--draft", f"--prerelease={str(version.prerelease).lower()}", "--latest=false",
            "--title", f"OpenRay {version.version}", "--generate-notes",
        )
        # A successful create can precede visibility in the releases listing.
        # Retry only this read; never create another draft or hide API errors.
        for attempt in range(5):
            matching = [release for release in github.releases() if release.get("tag_name") == version.tag]
            if matching or attempt == 4:
                break
            time.sleep(2)
        if len(matching) != 1:
            raise ReleaseError("Could not locate the newly created draft release.")
    release_id = matching[0].get("id")
    if type(release_id) is not int or release_id <= 0:
        raise ReleaseError("Remote release has an invalid ID.")
    release = github.current(release_id, version.tag)
    if not release["draft"]:
        if release.get("prerelease") != version.prerelease:
            raise ReleaseError("Published release prerelease status differs from the tag.")
        github.verify_assets(release_id, version.tag, hashes, complete=True)
        github.assert_tag(version.tag, sha)
        return f"Already published and verified: {version.tag}; no changes made."

    existing, changed = github.verify_assets(
        release_id, version.tag, hashes, complete=False, draft_provenance=(version.tag, sha),
    )
    for name in RELEASE_ASSETS:
        if name in existing and name not in changed:
            continue
        github.assert_tag(version.tag, sha)
        if not github.current(release_id, version.tag)["draft"]:
            raise ReleaseError("The release was published during upload; refusing further changes.")
        # Signing timestamps can change on a new run. Only this same-source draft
        # may be refreshed; published releases have already returned above.
        args = ["release", "upload", version.tag, str((directory / name).resolve()), "--repo", repo]
        if name in existing:
            args.append("--clobber")
        github.call(*args)
    github.verify_assets(release_id, version.tag, hashes, complete=True)
    github.assert_tag(version.tag, sha)
    release = github.current(release_id, version.tag)
    if not release["draft"]:
        raise ReleaseError("The release was published by another actor; verified assets but refusing metadata changes.")
    if not public:
        return f"Draft ready with verified assets: {version.tag}"
    latest = should_be_latest(version, github.releases())
    # Recheck immediately before the only operation that makes the draft public.
    github.assert_tag(version.tag, sha)
    if not github.current(release_id, version.tag)["draft"]:
        raise ReleaseError("The release is no longer a draft; refusing metadata changes.")
    github.call(
        "release", "edit", version.tag, "--repo", repo, "--verify-tag", "--draft=false",
        f"--prerelease={str(version.prerelease).lower()}", f"--latest={str(latest).lower()}",
    )
    release = github.current(release_id, version.tag)
    if release["draft"] or release.get("prerelease") != version.prerelease:
        raise ReleaseError("GitHub did not confirm the expected published release state.")
    github.assert_tag(version.tag, sha)
    return f"Published verified release: {version.tag} (latest={str(latest).lower()})"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    metadata_parser = commands.add_parser("metadata", help="Print validated GitHub Actions version outputs.")
    stage_parser = commands.add_parser("stage", help="Stage production packages using stable download asset names.")
    publish_parser = commands.add_parser("publish", help="Upload and verify a draft, optionally publish it.")
    for command in (metadata_parser, stage_parser, publish_parser):
        command.add_argument("--tag", required=True)
    for command in (metadata_parser, stage_parser):
        command.add_argument("--build-number", required=True)
    stage_parser.add_argument("--package-dir", type=Path, required=True)
    stage_parser.add_argument("--output", type=Path, required=True)
    stage_parser.add_argument("--sha", required=True)
    publish_parser.add_argument("--directory", type=Path, required=True)
    publish_parser.add_argument("--repo", required=True)
    publish_parser.add_argument("--sha", required=True)
    publish_parser.add_argument("--publish", action="store_true", help="Publish only after all draft assets verify.")
    args = parser.parse_args()
    try:
        version = parse_tag(args.tag)
        if args.command == "metadata":
            parse_build_number(args.build_number)
            for name, value in (
                ("tag", version.tag), ("version", version.version),
                ("marketing_version", version.marketing_version),
                ("prerelease", str(version.prerelease).lower()),
            ):
                print(f"{name}={value}")
        elif args.command == "stage":
            stage(args.package_dir, args.output, version, parse_build_number(args.build_number), args.sha)
            print(f"Staged production package assets: {args.output}")
        else:
            print(publish(args.directory, args.repo, version, args.sha, public=args.publish))
    except (ReleaseError, OSError, json.JSONDecodeError) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
