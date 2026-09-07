#!/bin/zsh
# Build Apple silicon direct-download artifacts. No secrets belong in this file.
set -euo pipefail

OPENRAY_ROOT="${0:A:h:h}"
cd "$OPENRAY_ROOT"
OPENRAY_PREVIEW=0
OPENRAY_SKIP_TESTS=0
OPENRAY_OUTPUT=""
OPENRAY_VERSION_OVERRIDE=""
OPENRAY_BUILD_OVERRIDE=""
typeset -a OPENRAY_BUILD_SETTINGS OPENRAY_SIGNING_KEYCHAIN_ARGS OPENRAY_NOTARY_KEYCHAIN_ARGS
OPENRAY_BUILD_SETTINGS=()
OPENRAY_SIGNING_KEYCHAIN_ARGS=()
OPENRAY_NOTARY_KEYCHAIN_ARGS=()
if [[ -n "${OPENRAY_SIGNING_KEYCHAIN:-}" ]]; then
  OPENRAY_SIGNING_KEYCHAIN_ARGS=(--keychain "$OPENRAY_SIGNING_KEYCHAIN")
fi
if [[ -n "${OPENRAY_NOTARY_KEYCHAIN:-}" ]]; then
  OPENRAY_NOTARY_KEYCHAIN_ARGS=(--keychain "$OPENRAY_NOTARY_KEYCHAIN")
fi

usage() {
  cat <<'USAGE'
Usage: ./scripts/package-release.sh [--preview] [--skip-tests] [--output NEW_DIRECTORY]
                                  [--version X.Y.Z] [--build-number INTEGER]

The default mode requires:
  OPENRAY_SIGNING_IDENTITY  Full installed "Developer ID Application: …" certificate name
  OPENRAY_NOTARY_PROFILE    Existing notarytool Keychain profile name

The default mode signs, notarizes, staples, and assesses both the app and DMG.
--preview creates clearly labeled ad-hoc-signed artifacts for local inspection only.
--skip-tests is for a source revision already verified with scripts/verify.sh.
The output directory must not exist; previous release artifacts are never overwritten.
Version and build overrides affect this archive only; source settings are not rewritten.
Optional OPENRAY_SIGNING_KEYCHAIN and OPENRAY_NOTARY_KEYCHAIN isolate CI credentials.
USAGE
}

fail() { print -u2 -- "$1"; exit 1; }
while (( $# )); do
  case "$1" in
    --preview) OPENRAY_PREVIEW=1; shift ;;
    --skip-tests) OPENRAY_SKIP_TESTS=1; shift ;;
    --output)
      (( $# >= 2 )) || fail '--output requires a new directory.'
      OPENRAY_OUTPUT="$2"; shift 2 ;;
    --version)
      (( $# >= 2 )) || fail '--version requires X.Y.Z.'
      OPENRAY_VERSION_OVERRIDE="$2"; shift 2 ;;
    --build-number)
      (( $# >= 2 )) || fail '--build-number requires a positive integer.'
      OPENRAY_BUILD_OVERRIDE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done

if [[ -n "$OPENRAY_VERSION_OVERRIDE" ]]; then
  [[ "$OPENRAY_VERSION_OVERRIDE" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]] || fail 'Version must be canonical X.Y.Z.'
  OPENRAY_BUILD_SETTINGS+=("MARKETING_VERSION=$OPENRAY_VERSION_OVERRIDE")
fi
if [[ -n "$OPENRAY_BUILD_OVERRIDE" ]]; then
  [[ "$OPENRAY_BUILD_OVERRIDE" =~ '^[1-9][0-9]*$' ]] || fail 'Build number must be a positive integer without leading zeros.'
  OPENRAY_BUILD_SETTINGS+=("CURRENT_PROJECT_VERSION=$OPENRAY_BUILD_OVERRIDE")
fi

if (( ! OPENRAY_PREVIEW )); then
  [[ "${OPENRAY_SIGNING_IDENTITY:-}" == 'Developer ID Application: '* ]] ||
    fail 'Set OPENRAY_SIGNING_IDENTITY to an installed Developer ID Application certificate. Apple Development and ad-hoc signatures cannot ship.'
  typeset -a OPENRAY_IDENTITY_KEYCHAIN_ARGS=()
  [[ -z "${OPENRAY_SIGNING_KEYCHAIN:-}" ]] || OPENRAY_IDENTITY_KEYCHAIN_ARGS=("$OPENRAY_SIGNING_KEYCHAIN")
  security find-identity -v -p codesigning "${OPENRAY_IDENTITY_KEYCHAIN_ARGS[@]}" | /usr/bin/grep -F -- "\"$OPENRAY_SIGNING_IDENTITY\"" >/dev/null ||
    fail 'The requested Developer ID Application certificate and private key are not available in this Keychain.'
  [[ -n "${OPENRAY_NOTARY_PROFILE:-}" ]] || fail 'Set OPENRAY_NOTARY_PROFILE to an existing notarytool Keychain profile. See docs/RELEASE.md.'
  xcrun notarytool history --keychain-profile "$OPENRAY_NOTARY_PROFILE" "${OPENRAY_NOTARY_KEYCHAIN_ARGS[@]}" --output-format json >/dev/null
fi

[[ -n "$OPENRAY_OUTPUT" ]] || OPENRAY_OUTPUT="$OPENRAY_ROOT/.build/releases/$(date -u +%Y%m%dT%H%M%SZ)"
OPENRAY_OUTPUT="${OPENRAY_OUTPUT:A}"
[[ ! -e "$OPENRAY_OUTPUT" ]] || fail "Output already exists: $OPENRAY_OUTPUT"
mkdir -p "$OPENRAY_OUTPUT"
trap 'print -u2 -- "Packaging did not finish. Inspect logs in $OPENRAY_OUTPUT; do not distribute incomplete artifacts."' ZERR

if (( ! OPENRAY_SKIP_TESTS )); then
  print 'Running deterministic tests…'
  ./scripts/verify.sh >"$OPENRAY_OUTPUT/tests.log" 2>&1
fi

print 'Archiving the Release build for Apple silicon…'
xcodebuild -project OpenRay.xcodeproj -scheme OpenRay -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$OPENRAY_ROOT/.build/release" \
  -archivePath "$OPENRAY_OUTPUT/OpenRay.xcarchive" archive \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO "${OPENRAY_BUILD_SETTINGS[@]}" -quiet \
  >"$OPENRAY_OUTPUT/archive.log" 2>&1

OPENRAY_STAGING="$OPENRAY_OUTPUT/staging"
OPENRAY_APP="$OPENRAY_STAGING/OpenRay.app"
mkdir "$OPENRAY_STAGING"
ditto "$OPENRAY_OUTPUT/OpenRay.xcarchive/Products/Applications/OpenRay.app" "$OPENRAY_APP"
OPENRAY_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OPENRAY_APP/Contents/Info.plist")
OPENRAY_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OPENRAY_APP/Contents/Info.plist")
[[ -z "$OPENRAY_VERSION_OVERRIDE" || "$OPENRAY_VERSION" == "$OPENRAY_VERSION_OVERRIDE" ]] || fail 'The archive version does not match the requested version.'
[[ -z "$OPENRAY_BUILD_OVERRIDE" || "$OPENRAY_BUILD" == "$OPENRAY_BUILD_OVERRIDE" ]] || fail 'The archive build does not match the requested build number.'
[[ "$OPENRAY_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail 'Expected a three-part numeric marketing version.'
[[ "$(lipo -archs "$OPENRAY_APP/Contents/MacOS/OpenRay")" == arm64 ]] || fail 'Expected an Apple silicon-only executable.'
plutil -lint "$OPENRAY_APP/Contents/Resources/PrivacyInfo.xcprivacy"
[[ -f "$OPENRAY_APP/Contents/Resources/AppIcon.icns" ]] || fail 'The archive is missing its app icon.'

OPENRAY_NAME="OpenRay-$OPENRAY_VERSION"
if (( OPENRAY_PREVIEW )); then
  OPENRAY_NAME+="-local-preview"
  codesign --force --sign - --options runtime "$OPENRAY_APP"
else
  codesign --force --sign "$OPENRAY_SIGNING_IDENTITY" "${OPENRAY_SIGNING_KEYCHAIN_ARGS[@]}" --options runtime --timestamp "$OPENRAY_APP"
fi
codesign --verify --strict --verbose=2 "$OPENRAY_APP" 2>"$OPENRAY_OUTPUT/signature-verification.log"
codesign -d --verbose=4 "$OPENRAY_APP" 2>"$OPENRAY_OUTPUT/signature-details.txt"
/usr/bin/grep -q 'runtime' "$OPENRAY_OUTPUT/signature-details.txt" || fail 'Hardened runtime is missing.'
if (( ! OPENRAY_PREVIEW )); then
  /usr/bin/grep -q '^Authority=Developer ID Application:' "$OPENRAY_OUTPUT/signature-details.txt" || fail 'Unexpected signing authority.'
  /usr/bin/grep -q '^Timestamp=' "$OPENRAY_OUTPUT/signature-details.txt" || fail 'The signature has no secure timestamp.'
fi
codesign -d --entitlements - "$OPENRAY_APP" >"$OPENRAY_OUTPUT/entitlements.plist" 2>/dev/null
# This app requires no code-signing entitlements. Refuse a debugger entitlement if one appears.
if [[ -s "$OPENRAY_OUTPUT/entitlements.plist" ]] &&
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$OPENRAY_OUTPUT/entitlements.plist" 2>/dev/null || true)" == true ]]; then
  fail 'Release signature unexpectedly permits debugger attachment.'
fi

notarize() {
  local openray_artifact="$1"
  local openray_label="$2"
  print -- "Notarizing $openray_label…"
  local openray_submit_status=0
  xcrun notarytool submit "$openray_artifact" --keychain-profile "$OPENRAY_NOTARY_PROFILE" \
    "${OPENRAY_NOTARY_KEYCHAIN_ARGS[@]}" --wait --timeout 30m --output-format json >"$OPENRAY_OUTPUT/$openray_label-notarization.json" || openray_submit_status=$?
  local openray_submission
  openray_submission=$(plutil -extract id raw "$OPENRAY_OUTPUT/$openray_label-notarization.json" 2>/dev/null) ||
    fail "No submission ID returned for $openray_label. Inspect its output before retrying."
  xcrun notarytool log "$openray_submission" --keychain-profile "$OPENRAY_NOTARY_PROFILE" \
    "${OPENRAY_NOTARY_KEYCHAIN_ARGS[@]}" "$OPENRAY_OUTPUT/$openray_label-notarization-log.json"
  (( openray_submit_status == 0 )) &&
    [[ "$(plutil -extract status raw "$OPENRAY_OUTPUT/$openray_label-notarization.json")" == Accepted ]] ||
    fail "Apple did not accept $openray_label. Review its notarization log."
}

if (( ! OPENRAY_PREVIEW )); then
  ditto -c -k --keepParent "$OPENRAY_APP" "$OPENRAY_OUTPUT/notarization-upload.zip"
  notarize "$OPENRAY_OUTPUT/notarization-upload.zip" app
  xcrun stapler staple "$OPENRAY_APP"
  xcrun stapler validate "$OPENRAY_APP"
  spctl --assess --type execute --verbose=2 "$OPENRAY_APP" 2>"$OPENRAY_OUTPUT/app-gatekeeper.log"
  syspolicy_check distribution "$OPENRAY_APP" >"$OPENRAY_OUTPUT/distribution-check.log" 2>&1
fi

# Package after stapling: offline installs from either artifact retain the app ticket.
ditto -c -k --keepParent "$OPENRAY_APP" "$OPENRAY_OUTPUT/$OPENRAY_NAME.zip"
ln -s /Applications "$OPENRAY_STAGING/Applications"
cat >"$OPENRAY_STAGING/Install OpenRay.txt" <<'INSTALL'
Drag OpenRay to Applications, then open it there.
OpenRay requires an Apple silicon Mac with macOS 26 or later. Press Option-Space to open the launcher.
If that shortcut is in use, choose another in Settings from the OpenRay menu bar item.
Clipboard history and snippet expansion are off by default. Accessibility is optional.
For help and privacy information, choose OpenRay Help from the menu bar.
INSTALL
if (( OPENRAY_PREVIEW )); then
  print 'LOCAL PREVIEW ONLY — ad-hoc signed, not notarized, not for distribution.' >"$OPENRAY_STAGING/LOCAL PREVIEW ONLY.txt"
fi
hdiutil create -volname "${OPENRAY_NAME}" -srcfolder "$OPENRAY_STAGING" -format UDZO \
  "$OPENRAY_OUTPUT/$OPENRAY_NAME.dmg" >"$OPENRAY_OUTPUT/dmg.log"
if (( ! OPENRAY_PREVIEW )); then
  codesign --force --sign "$OPENRAY_SIGNING_IDENTITY" "${OPENRAY_SIGNING_KEYCHAIN_ARGS[@]}" --timestamp "$OPENRAY_OUTPUT/$OPENRAY_NAME.dmg"
  notarize "$OPENRAY_OUTPUT/$OPENRAY_NAME.dmg" dmg
  xcrun stapler staple "$OPENRAY_OUTPUT/$OPENRAY_NAME.dmg"
  xcrun stapler validate "$OPENRAY_OUTPUT/$OPENRAY_NAME.dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 \
    "$OPENRAY_OUTPUT/$OPENRAY_NAME.dmg" 2>"$OPENRAY_OUTPUT/dmg-gatekeeper.log"
fi
hdiutil verify "$OPENRAY_OUTPUT/$OPENRAY_NAME.dmg" >"$OPENRAY_OUTPUT/dmg-verification.log"
(
  cd "$OPENRAY_OUTPUT"
  shasum -a 256 "$OPENRAY_NAME.zip" "$OPENRAY_NAME.dmg" >SHA256SUMS
)
{
  print -- "OpenRay $OPENRAY_VERSION ($OPENRAY_BUILD)"
  print -- "Source commit: $(git rev-parse HEAD)"
  print -- "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  print -- "Local preview: $OPENRAY_PREVIEW"
  print -- "Tests skipped by caller: $OPENRAY_SKIP_TESTS"
  print 'Working tree changes at build time:'
  git status --short
} >"$OPENRAY_OUTPUT/build-info.txt"
if (( OPENRAY_PREVIEW )); then
  print 'Local package checks passed. This preview has no Developer ID signature or notarization.' >"$OPENRAY_OUTPUT/PREVIEW-ONLY.txt"
else
  print 'Developer ID signatures, notarization, stapling, Gatekeeper assessment and DMG integrity checks passed. Complete the clean-Mac download smoke test before publishing.' >"$OPENRAY_OUTPUT/READY-FOR-SMOKE-TEST.txt"
fi
print -- "Artifacts and verification logs: $OPENRAY_OUTPUT"
