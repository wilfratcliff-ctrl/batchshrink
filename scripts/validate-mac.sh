#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This script requires macOS and Xcode." >&2
  exit 1
fi
command -v xcodegen >/dev/null
xcodebuild -version
xcodegen --version
plutil -lint VideoShrink/Resources/Info.plist VideoShrink/Resources/PrivacyInfo.xcprivacy
xcodegen generate
xcodebuild -project VideoShrink.xcodeproj -scheme VideoShrink \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
if [[ -n "${SIMULATOR_UDID:-}" ]]; then
  xcodebuild -project VideoShrink.xcodeproj -scheme VideoShrink \
    -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
    -derivedDataPath build/DerivedData -resultBundlePath "build/Tests-$(date +%Y%m%d-%H%M%S).xcresult" \
    CODE_SIGNING_ALLOWED=NO test
else
  echo 'Build complete. Tests NOT run: set SIMULATOR_UDID from xcrun simctl list devices available and rerun.'
fi
