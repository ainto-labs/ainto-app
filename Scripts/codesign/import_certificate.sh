#!/usr/bin/env bash
# Import certificate into login keychain
# Imports certificate into login keychain and sets trust

set -exu

certificateFile="$1"
certificatePassword="$2"

# Import p12 into Keychain
security import $certificateFile.p12 -P $certificatePassword -T /usr/bin/codesign

# Set Trust > Code Signing > "Always Trust"
security add-trusted-cert -d -r trustRoot -p codeSign $certificateFile.crt
