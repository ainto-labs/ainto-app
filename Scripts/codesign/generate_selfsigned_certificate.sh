#!/usr/bin/env bash
# Generate a self-signed code signing certificate
# Generates a self-signed certificate using OpenSSL

set -exu

certificateFile="$1"
certificatePassword="$2"

# Certificate request config (see https://apple.stackexchange.com/q/359997)
cat >$certificateFile.conf <<EOL
  [ req ]
  distinguished_name = req_name
  prompt = no
  [ req_name ]
  CN = Local Self-Signed
  [ extensions ]
  basicConstraints=critical,CA:false
  keyUsage=critical,digitalSignature
  extendedKeyUsage=critical,1.3.6.1.5.5.7.3.3
  1.2.840.113635.100.6.1.14=critical,DER:0500
EOL

# Generate key
openssl genrsa -out $certificateFile.key 2048

# Generate self-signed certificate
openssl req -x509 -new -config $certificateFile.conf -nodes -key $certificateFile.key -extensions extensions -sha256 -out $certificateFile.crt

# Determine openssl version for compatibility
openssl_version=$(openssl version)
# OpenSSL v3.x requires -legacy flag
# see https://www.misterpki.com/openssl-pkcs12-legacy/
if [[ $openssl_version == OpenSSL\ 3* ]]; then
  flag="-legacy"
else
  flag=""
fi

# Wrap key and certificate into PKCS12
openssl pkcs12 $flag -export -inkey $certificateFile.key -in $certificateFile.crt -out $certificateFile.p12 -passout pass:$certificatePassword
