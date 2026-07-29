#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
PROJECT="$PROJECT_ROOT/Mobile/DropsiftMobile.xcodeproj"
DERIVED_DATA="$PROJECT_ROOT/.build/mobile-derived-data"

if [[ ! -d "$PROJECT" ]]; then
    "$SCRIPT_DIR/generate-mobile-project.sh"
fi

xcodebuild \
    -project "$PROJECT" \
    -scheme DropsiftMobile \
    -configuration Debug \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA/ios" \
    CODE_SIGNING_ALLOWED=NO \
    build

xcodebuild \
    -project "$PROJECT" \
    -scheme DropsiftWatch \
    -configuration Debug \
    -destination "generic/platform=watchOS Simulator" \
    -derivedDataPath "$DERIVED_DATA/watch" \
    CODE_SIGNING_ALLOWED=NO \
    build

print "Built iPhone and Apple Watch simulator apps."
