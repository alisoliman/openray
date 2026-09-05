#!/bin/zsh
set -euo pipefail

OPENRAY_ROOT="${0:A:h:h}"
cd "$OPENRAY_ROOT"

OPENRAY_AI_CHECK=0
OPENRAY_ARCH="$(uname -m)"
if [[ "${1:-}" == "--ai" ]]; then
  OPENRAY_AI_CHECK=1
elif [[ -n "${1:-}" ]]; then
  print -u2 'Usage: ./scripts/verify.sh [--ai]'
  exit 2
fi

xcodebuild -project OpenRay.xcodeproj -scheme OpenRay \
  -destination "platform=macOS,arch=$OPENRAY_ARCH" -derivedDataPath .build/verification \
  test CODE_SIGNING_ALLOWED=NO OPENRAY_TEST_AI="$OPENRAY_AI_CHECK" -quiet
