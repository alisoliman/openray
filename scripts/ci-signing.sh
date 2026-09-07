#!/bin/bash
# Import existing release credentials only on an ephemeral GitHub Actions runner.
# Never create certificates, change the default keychain, or print credential output.
set +x
set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage: ./scripts/ci-signing.sh setup | cleanup

setup requires a GitHub-hosted macOS runner, RUNNER_TEMP, GITHUB_ENV, and secrets:
  APPLE_CERTIFICATE_P12_BASE64   Exported Developer ID Application certificate + key
  APPLE_CERTIFICATE_PASSWORD    Password protecting the exported P12
  APPLE_NOTARY_KEY_P8_BASE64     App Store Connect team API private key
  APPLE_NOTARY_KEY_ID           API key ID
  APPLE_NOTARY_ISSUER_ID        Team API issuer UUID

OPENRAY_SIGNING_IDENTITY may select one full Developer ID Application name when
the P12 contains more than one valid identity. Otherwise it is detected.

setup writes the identity, signing/notary keychain paths, notary profile, and
temporary directory to GITHUB_ENV. Packaging must use those explicit keychains.
Run cleanup in an always() step in the same job. No credentials are created here.
USAGE
}

fail() { printf '%s\n' "$1" >&2; exit 1; }

decode_secret() {
  local openray_encoded
  # macOS base64 silently skips invalid characters, so validate before decoding.
  openray_encoded=$(printf '%s' "$1" | tr -d '\r\n\t ')
  [[ -n "$openray_encoded" && "$openray_encoded" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] || return 1
  printf '%s' "$openray_encoded" | base64 --decode >"$2" 2>/dev/null
}

# Only files created by this script are removed. A malformed path must never
# turn cleanup into deletion of a runner directory or an existing user keychain.
cleanup_directory() {
  local openray_directory="$1"
  local openray_cleanup_result=0
  local openray_runner_root
  [[ -n "$openray_directory" ]] || return 0
  [[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" ]] || return 1
  openray_runner_root=$(cd "$RUNNER_TEMP" && pwd -P) || return 1
  [[ "${openray_directory%/*}" == "$openray_runner_root" ]] || return 1
  [[ "${openray_directory##*/}" =~ ^openray-signing\.[A-Za-z0-9]{8}$ ]] || return 1
  [[ ! -L "$openray_directory" ]] || return 1
  [[ -d "$openray_directory" ]] || return 0
  [[ -f "$openray_directory/.openray-ci-signing" && ! -L "$openray_directory/.openray-ci-signing" ]] || return 1

  if [[ -f "$openray_directory/release.keychain-db" && ! -L "$openray_directory/release.keychain-db" ]]; then
    security delete-keychain "$openray_directory/release.keychain-db" >/dev/null 2>&1 || openray_cleanup_result=1
  fi
  # Also remove a keychain file if the security tool could not delete it.
  rm -f -- "$openray_directory/certificate.p12" "$openray_directory/notary-key.p8" \
    "$openray_directory/release.keychain-db" "$openray_directory/.openray-ci-signing" || openray_cleanup_result=1
  rmdir -- "$openray_directory" || openray_cleanup_result=1
  return "$openray_cleanup_result"
}

[[ $# == 1 ]] || { usage >&2; exit 1; }
case "$1" in
  --help|-h) usage; exit 0 ;;
  cleanup)
    cleanup_directory "${OPENRAY_SIGNING_DIRECTORY:-}" || fail 'Unable to fully clean up the temporary signing keychain.'
    printf 'Temporary signing credentials removed.\n'
    exit 0
    ;;
  setup) ;;
  *) usage >&2; fail 'Expected setup or cleanup.' ;;
esac

[[ "${GITHUB_ACTIONS:-}" == true ]] || fail 'Signing setup is restricted to GitHub Actions runners.'
[[ "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || fail 'Signing setup requires an ephemeral GitHub-hosted runner.'
[[ "$(uname -s)" == Darwin ]] || fail 'Signing setup requires a macOS runner.'
[[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" ]] || fail 'RUNNER_TEMP must identify an existing runner temporary directory.'
[[ -n "${GITHUB_ENV:-}" && -f "$GITHUB_ENV" && -w "$GITHUB_ENV" ]] || fail 'GITHUB_ENV must identify the writable GitHub Actions environment file.'
[[ -z "${OPENRAY_SIGNING_DIRECTORY:-}" ]] || fail 'Signing is already configured; clean it up before setting it up again.'
for openray_input in APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD \
  APPLE_NOTARY_KEY_P8_BASE64 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID; do
  [[ -n "${!openray_input:-}" ]] || fail "Required GitHub Actions secret is missing: $openray_input"
done
[[ "$APPLE_NOTARY_KEY_ID" =~ ^[A-Za-z0-9]{10,}$ ]] || fail 'APPLE_NOTARY_KEY_ID must be an App Store Connect API key ID.'
[[ "$APPLE_NOTARY_ISSUER_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
  fail 'APPLE_NOTARY_ISSUER_ID must be the UUID for an App Store Connect team API key.'

openray_runner_root=$(cd "$RUNNER_TEMP" && pwd -P)
[[ "$openray_runner_root" != *$'\n'* && "$openray_runner_root" != *$'\r'* ]] || fail 'RUNNER_TEMP cannot contain line breaks.'
OPENRAY_SIGNING_DIRECTORY=$(mktemp -d "$openray_runner_root/openray-signing.XXXXXXXX")
touch "$OPENRAY_SIGNING_DIRECTORY/.openray-ci-signing"
openray_setup_complete=0
finish_setup() {
  local openray_exit_status=$?
  trap - EXIT INT TERM
  if [[ "$openray_setup_complete" != 1 ]]; then
    cleanup_directory "$OPENRAY_SIGNING_DIRECTORY" || printf 'Temporary credential cleanup failed; discard this runner.\n' >&2
  fi
  exit "$openray_exit_status"
}
trap finish_setup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

openray_certificate="$OPENRAY_SIGNING_DIRECTORY/certificate.p12"
openray_notary_key="$OPENRAY_SIGNING_DIRECTORY/notary-key.p8"
OPENRAY_SIGNING_KEYCHAIN="$OPENRAY_SIGNING_DIRECTORY/release.keychain-db"
OPENRAY_NOTARY_KEYCHAIN="$OPENRAY_SIGNING_KEYCHAIN"
OPENRAY_NOTARY_PROFILE='openray-ci-release'

decode_secret "$APPLE_CERTIFICATE_P12_BASE64" "$openray_certificate" || fail 'Unable to decode APPLE_CERTIFICATE_P12_BASE64.'
decode_secret "$APPLE_NOTARY_KEY_P8_BASE64" "$openray_notary_key" || fail 'Unable to decode APPLE_NOTARY_KEY_P8_BASE64.'
[[ -s "$openray_certificate" && -s "$openray_notary_key" ]] || fail 'Decoded Apple credential files must not be empty.'
openssl pkey -in "$openray_notary_key" -passin pass: -noout >/dev/null 2>&1 || fail 'APPLE_NOTARY_KEY_P8_BASE64 does not contain a readable private key.'

openray_keychain_password=$(openssl rand -hex 32)
# security accepts these passwords as arguments; xtrace is disabled and all of
# its credential-handling output is suppressed. This job must use a hosted VM.
security create-keychain -p "$openray_keychain_password" "$OPENRAY_SIGNING_KEYCHAIN" >/dev/null 2>&1 || fail 'Unable to create the temporary signing keychain.'
security set-keychain-settings -lut 21600 "$OPENRAY_SIGNING_KEYCHAIN" >/dev/null 2>&1 || fail 'Unable to configure the temporary signing keychain.'
security unlock-keychain -p "$openray_keychain_password" "$OPENRAY_SIGNING_KEYCHAIN" >/dev/null 2>&1 || fail 'Unable to unlock the temporary signing keychain.'
security import "$openray_certificate" -k "$OPENRAY_SIGNING_KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" \
  -f pkcs12 -T /usr/bin/codesign >/dev/null 2>&1 || fail 'Unable to import the signing certificate; check the P12 and its password.'
rm -f -- "$openray_certificate"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$openray_keychain_password" \
  "$OPENRAY_SIGNING_KEYCHAIN" >/dev/null 2>&1 || fail 'Unable to grant codesign access to the imported signing key.'
unset openray_keychain_password

openray_identity_output=$(security find-identity -v -p codesigning "$OPENRAY_SIGNING_KEYCHAIN" 2>/dev/null) || fail 'Unable to inspect the imported signing identity.'
openray_identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-Fa-f]{40}[[:space:]]+"(Developer ID Application: [^"]+)"[[:space:]]*$'
openray_identities=()
while IFS= read -r openray_line; do
  if [[ "$openray_line" =~ $openray_identity_pattern ]]; then
    if [[ -z "${OPENRAY_SIGNING_IDENTITY:-}" || "$OPENRAY_SIGNING_IDENTITY" == "${BASH_REMATCH[1]}" ]]; then
      openray_identities[${#openray_identities[@]}]="${BASH_REMATCH[1]}"
    fi
  fi
done <<<"$openray_identity_output"
[[ ${#openray_identities[@]} == 1 ]] || fail 'Expected exactly one valid Developer ID Application identity. Export the correct certificate/private key or set OPENRAY_SIGNING_IDENTITY to its full name.'
OPENRAY_SIGNING_IDENTITY="${openray_identities[0]}"
[[ "$OPENRAY_SIGNING_IDENTITY" != *$'\r'* ]] || fail 'The signing identity cannot contain line breaks.'

# Validation is on by default: invalid/revoked keys fail before an archive is built.
xcrun notarytool store-credentials "$OPENRAY_NOTARY_PROFILE" --key "$openray_notary_key" \
  --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID" \
  --keychain "$OPENRAY_NOTARY_KEYCHAIN" >/dev/null 2>&1 || fail 'Unable to validate/store notarization credentials; check the team API key, key ID, issuer ID, and Apple service availability.'
rm -f -- "$openray_notary_key"
unset APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_NOTARY_KEY_P8_BASE64

{
  printf 'OPENRAY_SIGNING_IDENTITY=%s\n' "$OPENRAY_SIGNING_IDENTITY"
  printf 'OPENRAY_SIGNING_KEYCHAIN=%s\n' "$OPENRAY_SIGNING_KEYCHAIN"
  printf 'OPENRAY_NOTARY_PROFILE=%s\n' "$OPENRAY_NOTARY_PROFILE"
  printf 'OPENRAY_NOTARY_KEYCHAIN=%s\n' "$OPENRAY_NOTARY_KEYCHAIN"
  printf 'OPENRAY_SIGNING_DIRECTORY=%s\n' "$OPENRAY_SIGNING_DIRECTORY"
} >>"$GITHUB_ENV"
openray_setup_complete=1
printf 'Existing signing and notarization credentials are ready in a temporary keychain.\n'
