#!/bin/bash
set -euo pipefail

# Bump version across all 4 files that must stay in sync.
#
# Usage:
#   ./Scripts/ci/bump-version.sh 0.1.2
#
# Files updated:
#   1. AintoApp/project.yml        (MARKETING_VERSION + CURRENT_PROJECT_VERSION)
#   2. AintoApp/Config/base.xcconfig (MARKETING_VERSION + CURRENT_PROJECT_VERSION)
#   3. AintoApp/Sources/App/Version.swift (appVersion)
#   4. ainto-core/Cargo.toml       (version)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 0.1.2" >&2
    exit 1
fi

VERSION="$1"

# Validate format
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Error: Invalid version format. Expected X.Y.Z (e.g., 0.1.2)" >&2
    exit 1
fi

BUILD_NUMBER=$("$SCRIPT_DIR/version-to-build-number.sh" "$VERSION")

echo "=== Bumping version to $VERSION (build $BUILD_NUMBER) ==="

# 1. project.yml
sed -i '' "s/MARKETING_VERSION: \"[0-9]*\.[0-9]*\.[0-9]*\"/MARKETING_VERSION: \"$VERSION\"/" \
    "$PROJECT_DIR/AintoApp/project.yml"
sed -i '' "s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" \
    "$PROJECT_DIR/AintoApp/project.yml"
echo "  project.yml: OK"

# 2. base.xcconfig
sed -i '' "s/MARKETING_VERSION = [0-9]*\.[0-9]*\.[0-9]*/MARKETING_VERSION = $VERSION/" \
    "$PROJECT_DIR/AintoApp/Config/base.xcconfig"
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = $BUILD_NUMBER/" \
    "$PROJECT_DIR/AintoApp/Config/base.xcconfig"
echo "  base.xcconfig: OK"

# 3. Version.swift
sed -i '' "s/appVersion = \"[0-9]*\.[0-9]*\.[0-9]*\"/appVersion = \"$VERSION\"/" \
    "$PROJECT_DIR/AintoApp/Sources/App/Version.swift"
echo "  Version.swift: OK"

# 4. Cargo.toml (only the package version, not dependencies)
sed -i '' "/^\[package\]/,/^$/ s/^version = \"[0-9]*\.[0-9]*\.[0-9]*\"/version = \"$VERSION\"/" \
    "$PROJECT_DIR/ainto-core/Cargo.toml"
echo "  Cargo.toml: OK"

# 5. Update Cargo.lock
(cd "$PROJECT_DIR/ainto-core" && cargo update -p ainto-core --quiet 2>/dev/null) || true
echo "  Cargo.lock: OK"

# Verify all 4 files match
echo ""
echo "=== Verifying ==="
FAIL=0

check() {
    local file="$1" actual="$2"
    if [ "$actual" != "$VERSION" ]; then
        echo "  MISMATCH: $file has $actual (expected $VERSION)" >&2
        FAIL=1
    else
        echo "  $file: $actual"
    fi
}

check "project.yml" "$(grep 'MARKETING_VERSION' "$PROJECT_DIR/AintoApp/project.yml" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')"
check "base.xcconfig" "$(grep 'MARKETING_VERSION' "$PROJECT_DIR/AintoApp/Config/base.xcconfig" | sed 's/.*= *//')"
check "Version.swift" "$(grep 'appVersion' "$PROJECT_DIR/AintoApp/Sources/App/Version.swift" | sed 's/.*"\([^"]*\)".*/\1/')"
check "Cargo.toml" "$(grep '^version' "$PROJECT_DIR/ainto-core/Cargo.toml" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')"

check_build() {
    local file="$1" actual="$2"
    if [ "$actual" != "$BUILD_NUMBER" ]; then
        echo "  MISMATCH: $file build number is $actual (expected $BUILD_NUMBER)" >&2
        FAIL=1
    else
        echo "  $file build: $actual"
    fi
}

check_build "project.yml" "$(grep 'CURRENT_PROJECT_VERSION' "$PROJECT_DIR/AintoApp/project.yml" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')"
check_build "base.xcconfig" "$(grep 'CURRENT_PROJECT_VERSION' "$PROJECT_DIR/AintoApp/Config/base.xcconfig" | sed 's/.*= *//')"

if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "ERROR: Version mismatch detected!" >&2
    exit 1
fi

echo ""
echo "=== All files bumped to $VERSION ==="
