#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
SPEC="$PROJECT_ROOT/Mobile/project.yml"

if command -v xcodegen >/dev/null 2>&1; then
    XCODEGEN=$(command -v xcodegen)
elif [[ -x "$PROJECT_ROOT/.tools/xcodegen/bin/xcodegen" ]]; then
    XCODEGEN="$PROJECT_ROOT/.tools/xcodegen/bin/xcodegen"
else
    print -u2 "XcodeGen 2.45.4+ is required."
    print -u2 "Install it with 'brew install xcodegen' or unpack xcodegen.zip into .tools/xcodegen."
    exit 1
fi

"$XCODEGEN" generate --spec "$SPEC" --project "$PROJECT_ROOT/Mobile"
print "Generated $PROJECT_ROOT/Mobile/DropsiftMobile.xcodeproj"
