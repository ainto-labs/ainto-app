#!/bin/bash
set -euo pipefail

# Validate release version
#
# Usage:
#   ./validate-release-version.sh 0.2.0
#
# Checks:
#   1. Version format is X.Y.Z
#   2. project.yml MARKETING_VERSION matches
#   3. project.yml + base.xcconfig CURRENT_PROJECT_VERSION match computed build number
#   4. CHANGELOG.md has entry for this version

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 0.2.0" >&2
    exit 1
fi

VERSION="$1"

echo "=== Validating release version: $VERSION ==="

# 1. Validate format (X.Y.Z)
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "::error::Invalid version format. Expected X.Y.Z (e.g., 0.2.0)" >&2
    exit 1
fi
echo "Format: OK"

# 2. Validate project.yml MARKETING_VERSION matches
YAML_VERSION=$(grep "MARKETING_VERSION" "$PROJECT_DIR/AintoApp/project.yml" | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/')
if [ "$YAML_VERSION" != "$VERSION" ]; then
    echo "::error::project.yml MARKETING_VERSION ($YAML_VERSION) doesn't match tag ($VERSION)" >&2
    exit 1
fi
echo "MARKETING_VERSION: OK ($YAML_VERSION)"

# 3. Validate CURRENT_PROJECT_VERSION matches computed build number
EXPECTED_BUILD=$("$SCRIPT_DIR/version-to-build-number.sh" "$VERSION")

YAML_BUILD=$(grep "CURRENT_PROJECT_VERSION" "$PROJECT_DIR/AintoApp/project.yml" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
if [ "$YAML_BUILD" != "$EXPECTED_BUILD" ]; then
    echo "::error::project.yml CURRENT_PROJECT_VERSION ($YAML_BUILD) doesn't match expected build number ($EXPECTED_BUILD for $VERSION)" >&2
    exit 1
fi

XCCONFIG_BUILD=$(grep "CURRENT_PROJECT_VERSION" "$PROJECT_DIR/AintoApp/Config/base.xcconfig" | sed 's/.*= *//')
if [ "$XCCONFIG_BUILD" != "$EXPECTED_BUILD" ]; then
    echo "::error::base.xcconfig CURRENT_PROJECT_VERSION ($XCCONFIG_BUILD) doesn't match expected build number ($EXPECTED_BUILD for $VERSION)" >&2
    exit 1
fi
echo "CURRENT_PROJECT_VERSION: OK ($EXPECTED_BUILD)"

# 4. Validate CHANGELOG.md has entry for this version
if [ -f "$PROJECT_DIR/CHANGELOG.md" ]; then
    if ! grep -q "^## \[$VERSION\]" "$PROJECT_DIR/CHANGELOG.md"; then
        echo "::error::CHANGELOG.md missing entry for version $VERSION" >&2
        exit 1
    fi
    echo "CHANGELOG.md: OK (found [$VERSION])"
else
    echo "CHANGELOG.md: SKIPPED (file not found)"
fi

echo "=== Validation passed ==="
