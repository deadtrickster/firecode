#!/usr/bin/env bash
# Build firecode-vz into vendor/bin and sign it.
#
# Virtualization.framework refuses to make a VM for a binary that does not
# carry the com.apple.security.virtualization entitlement, and an entitlement
# is part of a code signature. "-s -" is an ad-hoc signature: made locally, no
# certificate and no Apple account involved.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/../vendor/bin/firecode-vz}
mkdir -p "$(dirname "$out")"
swiftc -O -o "$out.new" "$here/firecode-vz.swift"
codesign --force -s - --entitlements "$here/firecode-vz.entitlements" "$out.new"
mv -f "$out.new" "$out"
echo "$out"
