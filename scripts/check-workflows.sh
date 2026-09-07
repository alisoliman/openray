#!/bin/bash
set -euo pipefail

# Pin both the version and official release checksum of this validation tool.
OPENRAY_ACTIONLINT_VERSION=1.7.12
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) OPENRAY_TOOL_PLATFORM=linux_amd64; OPENRAY_TOOL_SHA=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
  Darwin-arm64) OPENRAY_TOOL_PLATFORM=darwin_arm64; OPENRAY_TOOL_SHA=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f ;;
  *) echo 'Workflow lint supports Linux x86_64 and macOS Apple silicon.' >&2; exit 1 ;;
esac
OPENRAY_TOOL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/openray-actionlint.XXXXXX")
trap 'rm -rf "$OPENRAY_TOOL_DIR"' EXIT
OPENRAY_TOOL_FILE="actionlint_${OPENRAY_ACTIONLINT_VERSION}_${OPENRAY_TOOL_PLATFORM}.tar.gz"
curl --fail --location --silent --show-error --retry 3 \
  "https://github.com/rhysd/actionlint/releases/download/v${OPENRAY_ACTIONLINT_VERSION}/${OPENRAY_TOOL_FILE}" \
  --output "$OPENRAY_TOOL_DIR/$OPENRAY_TOOL_FILE"
(
  cd "$OPENRAY_TOOL_DIR"
  printf '%s  %s\n' "$OPENRAY_TOOL_SHA" "$OPENRAY_TOOL_FILE" | shasum -a 256 --check --status
  tar -xzf "$OPENRAY_TOOL_FILE" actionlint
)
# GitHub added queue:max in May 2026; actionlint 1.7.12 predates that schema.
# Ignore only that recognized-field gap, leaving other syntax diagnostics active.
"$OPENRAY_TOOL_DIR/actionlint" -color -shellcheck="" \
  -ignore '^unexpected key "queue" for "concurrency" section\.' "$@"
