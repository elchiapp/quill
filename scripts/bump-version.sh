#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
VERSION_FILE="$PROJECT_ROOT/VERSION"
BUILD_NUMBER_FILE="$PROJECT_ROOT/BUILD_NUMBER"

CURRENT_VERSION=$(/usr/bin/tr -d '[:space:]' < "$VERSION_FILE")
if [[ $# -gt 0 ]]; then
    NEXT_VERSION=$1
else
    PARTS=("${(@s:.:)CURRENT_VERSION}")
    if [[ ${#PARTS} -ne 3 ]]; then
        print -u2 "VERSION must use major.minor.patch format."
        exit 1
    fi
    NEXT_VERSION="${PARTS[1]}.${PARTS[2]}.$((PARTS[3] + 1))"
fi

if [[ ! "$NEXT_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "Version must use major.minor.patch format."
    exit 1
fi

TODAY=$(/bin/date +%Y%m%d)
CURRENT_BUILD=$(/usr/bin/tr -d '[:space:]' < "$BUILD_NUMBER_FILE")
if [[ "$CURRENT_BUILD" == "$TODAY"[0-9][0-9] ]]; then
    SEQUENCE=${CURRENT_BUILD#$TODAY}
    NEXT_SEQUENCE=$((10#$SEQUENCE + 1))
else
    NEXT_SEQUENCE=1
fi
NEXT_BUILD="$TODAY$(/usr/bin/printf '%02d' "$NEXT_SEQUENCE")"

/usr/bin/printf '%s\n' "$NEXT_VERSION" > "$VERSION_FILE"
/usr/bin/printf '%s\n' "$NEXT_BUILD" > "$BUILD_NUMBER_FILE"
/usr/bin/sed -E -i '' \
    -e "/<key>CFBundleShortVersionString<\\/key>/{n;s#<string>[^<]+</string>#<string>$NEXT_VERSION</string>#;}" \
    -e "/<key>CFBundleVersion<\\/key>/{n;s#<string>[^<]+</string>#<string>$NEXT_BUILD</string>#;}" \
    "$PROJECT_ROOT/Packaging/Info.plist"
/usr/bin/sed -E -i '' \
    "s/(CURRENT_PROJECT_VERSION: )[0-9]+/\\1$NEXT_BUILD/; s/(MARKETING_VERSION: )[0-9]+\.[0-9]+\.[0-9]+/\\1$NEXT_VERSION/" \
    "$PROJECT_ROOT/Mobile/project.yml"
/usr/bin/sed -E -i '' \
    "s/(CURRENT_PROJECT_VERSION = )[0-9]+;/\\1$NEXT_BUILD;/g; s/(MARKETING_VERSION = )[0-9]+\.[0-9]+\.[0-9]+;/\\1$NEXT_VERSION;/g" \
    "$PROJECT_ROOT/Mobile/DropsiftMobile.xcodeproj/project.pbxproj"

print "DropSift $NEXT_VERSION ($NEXT_BUILD)"
