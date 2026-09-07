# Contributing to OpenRay

Bug reports, documentation improvements, fixes, and feature proposals are welcome. You can help by reproducing an issue, testing a change on your Mac, or improving an explanation—writing code is only one way to contribute.

## Before you start

Search [existing issues](https://github.com/alisoliman/openray/issues) and [pull requests](https://github.com/alisoliman/openray/pulls) for related work. Small fixes and documentation changes can go straight to a pull request. For a substantial feature, new dependency, or change to architecture or the saved library format, open an issue to discuss the approach before implementing it.

Keep discussions respectful and focused on the problem. Explain tradeoffs and assume good intent when reviewing someone else's work.

## Report a bug or suggest a feature

For a bug, open an issue with:

- Your OpenRay version or commit, macOS version, and Mac model. Include Xcode's version for build problems.
- Steps to reproduce, what you expected, and what actually happened.
- Relevant settings and permission status. For window or cross-app issues, include the affected application and display setup.
- A screenshot, recording, or short log excerpt when it helps explain the problem.

Check the [troubleshooting notes](README.md#troubleshooting) first. Remove private clipboard contents, personal file paths, and credentials from anything you attach; a complete library export is not needed.

For a feature, describe the task you want to accomplish, your current workaround, and how the proposed behavior would help. Examples of the desired keyboard flow or interface are useful.

## Set up a development build

Use an Apple silicon Mac running macOS 26 or later and Xcode with the macOS 26 SDK or later. The project is tested with Xcode 26.6 / Swift 6.3.3. Apple Intelligence is needed only for live AI features and the optional model integration test.

1. Fork [alisoliman/openray](https://github.com/alisoliman/openray) on GitHub and clone your fork.
2. Create a descriptive branch from the current upstream `main`.
3. Open `OpenRay.xcodeproj`, select the **OpenRay** scheme, and run it.

The [build instructions](README.md#build-from-source) include a command for local ad-hoc signing. The checked-in Xcode project discovers source folders automatically and has no third-party package dependencies. Keep personal signing settings and generated build files out of your changes.

If you are new to forks and pull requests, GitHub's [contribution walkthrough](https://docs.github.com/en/get-started/exploring-projects-on-github/contributing-to-a-project) explains the workflow.

### Where changes belong

| Location | Responsibility |
| --- | --- |
| `OpenRay/App/` | Launcher state, navigation, panel lifecycle, and app coordination. |
| `OpenRay/Core/` | Data models, persistence, search matching, and calculator logic. |
| `OpenRay/Services/` | macOS integrations such as clipboard, file search, shortcuts, and windows. |
| `OpenRay/AI/` | Model integration and conversation state. |
| `OpenRay/Views/` | SwiftUI views and AppKit input adapters. |
| `OpenRayTests/` | Automated tests organized by feature. |
| `scripts/` | Verification, clipboard fixtures, app icon generation, and release tooling. |
| `docs/` | Privacy, support, and release documentation. |
| `.github/` | CI, release workflows, and dependency update configuration. |

## Code style

Follow the surrounding code and the repository's [`.swift-format`](.swift-format) configuration: four-space indentation and a 120-column line length. Use Swift 6 concurrency checking, keep UI state on the appropriate actor, and keep expensive work out of UI updates.

Use Xcode's bundled formatter to check the Swift files:

```sh
xcrun swift-format lint --strict --recursive OpenRay OpenRayTests scripts
```

To format a changed file, pass its path to `xcrun swift-format format --in-place`. Limit formatting to files you are changing so the pull request stays focused.

Preserve keyboard navigation, focus behavior, and accessibility labels when changing the interface. Changes to clipboard capture, permissions, AI imports, or persistence should preserve the behavior described in [Permissions and privacy](README.md#permissions-and-privacy). Document any intentional behavior change and explain its impact in the pull request.

## Test your changes

For code changes, run the automated suite from the repository root:

```sh
./scripts/verify.sh
```

Add or update tests for behavior changes and regression fixes. Existing tests use Swift Testing (`@Test`, `#expect`, and `#require`). Follow nearby tests for temporary libraries, private pasteboards, and injected AI engines; tests should not depend on a contributor's saved data or system clipboard.

When changing the live AI integration and Apple Intelligence is ready, also run:

```sh
./scripts/verify.sh --ai
```

If that test cannot run on your Mac, say so in the pull request. The default suite does not require the on-device model.

For UI changes, check keyboard navigation, focus after opening or closing an editor, and the affected view in light and dark appearance. The README describes [isolated UI and clipboard checks](README.md#verification). That mode disables global shortcuts, cross-app paste, snippet expansion, and login-item changes; verify those features separately when affected. Window manipulation also needs a manual check with Accessibility permission. Report what you tested.

For documentation-only changes, check links, examples, and Markdown formatting; an app rebuild is unnecessary.

For release tooling changes, run the corresponding Python tests:

```sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/test-ci-signing.py
```

For workflow changes, run `./scripts/check-workflows.sh`; it downloads a pinned, checksum-verified workflow linter. See the [release guide](docs/RELEASE.md) and [GitHub release pipeline](docs/GITHUB-RELEASES.md) for packaging and signing checks.

Pull request CI validates workflows and release tooling, runs the automated macOS tests, and packages an Apple silicon preview. Check its results before requesting a merge.

## Submit a pull request

Push your branch to your fork and open a pull request against **`alisoliman/openray:main`**. A draft pull request is welcome when you want feedback on an approach.

Use a descriptive title and include:

- The problem and resulting behavior, with a related issue link when available.
- The important implementation choices or tradeoffs.
- The commands and manual checks you ran, their results, and anything you could not verify.
- Before-and-after screenshots or a short recording for visible UI changes.

Before requesting review, check that:

- [ ] The diff addresses one coherent change and contains no unrelated formatting or generated build files.
- [ ] Relevant tests and formatting checks pass, or any limitations are explained.
- [ ] Documentation reflects changes to setup, shortcuts, permissions, or user-visible behavior.
- [ ] Shared project settings contain no personal signing configuration or local paths.

Respond to review feedback in the same pull request and explain any changes in approach. Maintainers will assess whether the contribution fits the project; opening a proposal or pull request does not guarantee that it will be merged.
