# GitHub releases

OpenRay's GitHub Actions pipeline prepares Apple silicon builds and publishes signed, notarized downloads. It uses Semantic Versioning tags, GitHub's native latest-release link, draft-first asset uploads, SHA-256 checksums, and build provenance. The app requires macOS 26 or later. Production signing still requires the Apple credentials described below; adding these workflows does not create those credentials or certify an existing preview.

## Workflows and release channels

| Workflow | Trigger | Result |
| --- | --- | --- |
| [CI](../.github/workflows/ci.yml) | Pull request, push to `main`, or manual run | Deterministic tests and an ad hoc signed installer preview saved as a workflow artifact. No Apple secrets. |
| [Release](../.github/workflows/release.yml) | Push a tag such as `v1.2.3` or `v1.3.0-rc.1` | Verify, sign, notarize, attest, and publish that version. |
| Release, manual | Existing remote `tag`; `publish` defaults to `false` | Prepare a draft release, or publish it when `publish` is `true`. |

The latest development preview is in the most recent successful [CI run](https://github.com/alisoliman/openray/actions/workflows/ci.yml). Workflow artifacts expire according to their retention setting and require GitHub access. They are labeled `local-preview`, have no Developer ID signature or notarization, and are not production downloads.

The latest stable download is at [Releases → Latest](https://github.com/alisoliman/openray/releases/latest). Each published tag also has its own permanent release page, for example `https://github.com/alisoliman/openray/releases/tag/v1.2.3`. Published versions keep the same asset names, so these links follow the latest stable release:

- [OpenRay for Apple silicon — DMG](https://github.com/alisoliman/openray/releases/latest/download/OpenRay-macos-arm64.dmg)
- [OpenRay for Apple silicon — ZIP](https://github.com/alisoliman/openray/releases/latest/download/OpenRay-macos-arm64.zip)
- [SHA-256 checksums](https://github.com/alisoliman/openray/releases/latest/download/SHA256SUMS)

These links resolve only after a stable release has been published. There is no moving `latest` Git tag. Versioned downloads use the same filenames under `/releases/download/v1.2.3/`. This follows [GitHub's release-link conventions](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).

## One-time configuration

Create a GitHub environment named **`release`** under **Settings → Environments**. Configure its deployment restrictions for the trusted release refs that the workflow uses. Store the following environment secrets under **Settings → Environments → release → Environment secrets**:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64-encoded `.p12` export of a Developer ID Application certificate **and its private key**. |
| `APPLE_CERTIFICATE_PASSWORD` | Password used to protect that `.p12` export. |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect API private key in `.p8` format. |
| `APPLE_NOTARY_KEY_ID` | The API key's Key ID. |
| `APPLE_NOTARY_ISSUER_ID` | The API key's Issuer ID. |

Use a team App Store Connect API key authorized for notarization. The issuer-based configuration is not the individual-key authentication flow. The `.p12` must contain a valid **Developer ID Application** identity; Apple Development and Developer ID Installer certificates do not sign this app for direct distribution. Obtain the credentials through the team's authorized Apple Developer workflow. See [Apple's Developer ID certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) and [notarytool migration guidance](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

Optionally set the environment variable `OPENRAY_SIGNING_IDENTITY` to the exact full Developer ID Application name to select. Otherwise, the signing helper requires exactly one valid imported Developer ID Application identity. Secrets are imported into a temporary runner Keychain, used for signing and notarization, and removed during cleanup. Do not put certificates, private keys, passwords, or generated Keychains in Git, workflow artifacts, or release assets.

Enable **Settings → General → Releases → Enable release immutability** to enforce server-side protection for future published versions. The workflow refuses to replace published assets, but GitHub's repository setting is what prevents later manual or API changes to those assets and tags. Titles, release notes, and latest/prerelease labels remain editable. Immutability applies to future releases and does not retrofit older ones. [GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases), [enable release immutability](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes).

Protect the default branch and release tags according to the repository's maintainer policy. Review changes to `.github/workflows/` and the release scripts as changes to the publishing process. These repository settings and credentials are setup steps; the workflow files do not apply them automatically.

## Publish a version

Choose a reviewed commit on `main` that contains these workflows and the desired app changes. Complete the interactive checks in [the release guide](RELEASE.md), including the real-model test on a Mac with Apple Intelligence ready. The hosted pipeline runs the deterministic suite; it does not establish that the on-device model or user-granted Accessibility features work on a fresh customer Mac.

Use a canonical [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html) version with a `v` prefix. Examples are `v0.1.0`, `v1.2.3`, and `v1.3.0-rc.1`. Increase the patch for compatible fixes, the minor for compatible features, and the major for incompatible changes to the public contract. SemVer treats `0.x` as initial development; make any compatibility expectations clear in the notes.

Create an annotated tag and push that exact tag:

```sh
git switch main
git pull --ff-only
git tag -a v1.2.3 -m 'OpenRay 1.2.3'
git push origin v1.2.3
```

Pushing a matching tag is a request to publish once all automated gates pass. The pipeline rejects invalid versions, resolves the tag to a specific commit, and requires that commit to be in the default branch's history. It checks out that exact commit for the build. Fix a failed release by correcting the cause and rerunning it; do not move a published version tag. If the source needs a correction, use a new version.

The tag's numeric core sets the app's `MARKETING_VERSION`: `v1.3.0-rc.1` produces an app version of `1.3.0`. The full tag remains in the GitHub release and `release.json`. `github.run_number` supplies the app build number; rerunning a workflow retains its run number. The workflow passes these values to `package-release.sh --version ... --build-number ...`, so a release tag does not require rewriting the development version in the source project.

Prerelease tags produce GitHub prereleases and never become Latest. For a stable version, publication compares its numeric SemVer with all existing published stable versions. A newer stable version becomes Latest; an older backport leaves Latest pointing at the newer version. Publication jobs use a shared concurrency queue so releases cannot race each other when deciding Latest. GitHub's automatic date-based choice is overridden explicitly. [GitHub Releases API](https://docs.github.com/en/rest/releases/releases), [concurrency queues](https://github.blog/changelog/2026-05-07-github-actions-concurrency-groups-now-allow-larger-queues/).

The versioned download and latest-release link do not add an automatic updater to the application. Users install updates by downloading and replacing the app.

## Prepare an existing tag manually

Run the workflow at the existing version tag, supply that same tag as the `tag` input, and leave `publish` unchecked to prepare a draft. The CLI makes the selected ref explicit:

```sh
gh workflow run release.yml --ref v1.2.3 -f tag=v1.2.3 -F publish=false
```

Use this for an existing unpublished tag or a release retry. A newly pushed version tag also triggers the automatic publishing path described above; a separate manual draft run does not cancel that path.

The workflow rejects dispatches from `main` or a different tag. The triggering commit must match the tag's resolved commit, which binds GitHub's build provenance to the actual source and rejects a tag that moved while the run was queued. The selected tag must already contain the release workflow.

To request publication from a manual run:

```sh
gh workflow run release.yml --ref v1.2.3 -f tag=v1.2.3 -F publish=true
```

Monitor the [Release workflow](https://github.com/alisoliman/openray/actions/workflows/release.yml) and inspect its summary and the resulting draft or published release. A failed signing, notarization, checksum, or upload check must be resolved before the version is presented as ready. Do not upload a `local-preview` artifact to a release to work around a failed production build.

If only publication fails, **Re-run failed jobs** reuses the successful build's artifact ID. A new complete run may refresh an unpublished draft for the same tag and source commit, then verify all uploaded bytes again. Published assets are never replaced by this pipeline; source corrections require a new version.

## Release contents and verification

The release assets are the final stapled DMG, a ZIP containing the stapled app, `SHA256SUMS`, and `release.json`. Build-provenance attestations are stored with GitHub and verified using `gh attestation verify`. `release.json` identifies the full version tag, source commit, and build. The pipeline uploads to a draft first and verifies uploaded asset hashes before publishing, consistent with [GitHub's recommended immutable-release workflow](https://cli.github.com/manual/gh_release_create).

Download and verify a specific version:

```sh
mkdir OpenRay-1.2.3
cd OpenRay-1.2.3
gh release download v1.2.3 --repo alisoliman/openray
shasum -a 256 -c SHA256SUMS
gh attestation verify OpenRay-macos-arm64.dmg --repo alisoliman/openray
gh attestation verify OpenRay-macos-arm64.zip --repo alisoliman/openray
```

Checksums detect changed bytes. GitHub build attestations identify the repository and workflow that produced those bytes. The Apple Developer ID signature and notarization establish the separate macOS distribution checks. See [GitHub artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations) and [the local release acceptance checks](RELEASE.md).

Both macOS workflows use GitHub's `macos-26` Apple silicon runner and select `/Applications/Xcode_26.6.app/Contents/Developer` explicitly. GitHub updates the host image over time, so inspect the recorded runner and Xcode versions when investigating a build. Update the selected Xcode deliberately when changing the toolchain. [Supported GitHub runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [macOS 26 arm64 image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).

Actions are pinned to full commit SHAs, and Dependabot proposes updates to those pins. Pull-request checks receive no Apple signing secrets. Signing credentials belong to the protected release environment; GitHub permissions are granted to the jobs that need them. These choices follow [GitHub's secure-use guidance](https://docs.github.com/en/actions/reference/security/secure-use).
