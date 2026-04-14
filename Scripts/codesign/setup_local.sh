#!/usr/bin/env bash
# Setup local self-signed certificate for Ainto development
# This prevents accessibility permission reset on every rebuild
#
# Usage: ./Scripts/codesign/setup_local.sh

set -exu

cd "$(dirname "$0")"

certificateFile="codesign"
certificatePassword=$(openssl rand -base64 12)

./generate_selfsigned_certificate.sh "$certificateFile" "$certificatePassword"
./import_certificate.sh "$certificateFile" "$certificatePassword"

# Cleanup temporary files
rm -f "${certificateFile}.conf" "${certificateFile}.key" "${certificateFile}.crt" "${certificateFile}.p12"

echo ""
echo "=== Setup Complete ==="
echo "Certificate 'Local Self-Signed' has been created and trusted."
echo "You can now build Ainto without accessibility permission resets."
echo ""
echo "Build with: make build"
