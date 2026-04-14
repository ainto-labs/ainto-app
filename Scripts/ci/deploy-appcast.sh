#!/bin/bash
set -euo pipefail

# Deploy appcast.xml to GitHub Pages
#
# Required environment variables:
#   VERSION              - Semantic version (e.g., 0.2.0)
#   BUILD_NUMBER         - Integer build number (e.g., 00200)
#   SIGNATURE            - Sparkle EdDSA signature
#   DMG_SIZE             - DMG file size in bytes
#   MACOS_MIN_VERSION    - Minimum macOS version (e.g., 14.0)
#   REPO_URL             - GitHub repo URL for downloads
#   APPCAST_URL          - Appcast URL

for var in VERSION BUILD_NUMBER SIGNATURE DMG_SIZE MACOS_MIN_VERSION REPO_URL APPCAST_URL; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var is not set"
        exit 1
    fi
done

PUB_DATE=$(date -R)

echo "=== Generating new appcast item ==="

cat > /tmp/new_item.xml << EOF
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MACOS_MIN_VERSION}</sparkle:minimumSystemVersion>
      <description><![CDATA[<a href="${REPO_URL}/releases/tag/v${VERSION}">View release notes</a>]]></description>
      <enclosure
        url="${REPO_URL}/releases/download/v${VERSION}/Ainto.dmg"
        length="${DMG_SIZE}"
        type="application/octet-stream"
        sparkle:edSignature="${SIGNATURE}"
      />
    </item>
EOF

cat /tmp/new_item.xml

echo "=== Switching to gh-pages ==="

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

git stash --include-untracked
git fetch origin gh-pages:gh-pages 2>/dev/null || true
git checkout gh-pages || git checkout --orphan gh-pages

echo "=== Extracting existing items ==="

if [ -f appcast.xml ]; then
    sed -n '/<item>/,/<\/item>/p' appcast.xml > /tmp/existing_items.xml || true
    echo "Found existing items:"
    cat /tmp/existing_items.xml
else
    touch /tmp/existing_items.xml
    echo "No existing appcast.xml found"
fi

echo "=== Building new appcast.xml ==="

cat > appcast.xml << HEADER
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Ainto Updates</title>
    <link>${APPCAST_URL}</link>
    <description>Most recent updates to Ainto</description>
    <language>en</language>
HEADER

cat /tmp/new_item.xml >> appcast.xml
cat /tmp/existing_items.xml >> appcast.xml

cat >> appcast.xml << 'FOOTER'
  </channel>
</rss>
FOOTER

echo "=== Final appcast.xml ==="
cat appcast.xml

echo "=== Committing and pushing ==="

git add appcast.xml
git commit -m "Update appcast.xml for v${VERSION}" || echo "No changes to commit"
git push origin gh-pages

echo "=== Done ==="
