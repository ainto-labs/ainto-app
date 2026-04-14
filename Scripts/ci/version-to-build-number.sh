#!/bin/bash
set -euo pipefail

# Convert semantic version to integer build number
#
# Usage:
#   ./version-to-build-number.sh 1.2.3    # Output: 10203
#   ./version-to-build-number.sh 0.2.0    # Output: 200
#
# Format: MAJOR * 10000 + MINOR * 100 + PATCH

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 1.2.3" >&2
    exit 1
fi

VERSION="$1"

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Error: Invalid version format '$VERSION'. Expected X.Y.Z" >&2
    exit 1
fi

BUILD_NUMBER=$(echo "$VERSION" | awk -F. '{ printf "%d", $1 * 10000 + $2 * 100 + $3 }')

echo "$BUILD_NUMBER"
