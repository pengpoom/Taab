#!/usr/bin/env bash

set -eu

projectRoot=$(cd "$(dirname "$0")/.." && pwd)
keychainPath="${HOME}/Library/Keychains/GlideDevelopment.keychain-db"
passwordFile="${HOME}/Library/Application Support/GlideDevelopment/keychain-password"

if [[ ! -f "$keychainPath" || ! -f "$passwordFile" ]]; then
    echo "Glide development signing is not configured. Run scripts/codesign/setup_local.sh first." >&2
    exit 1
fi

keychainPassword=$(/usr/bin/tr -d '\n' < "$passwordFile")
/usr/bin/security unlock-keychain -p "$keychainPassword" "$keychainPath"

if [[ $# -eq 0 ]]; then
    set -- \
        -project "$projectRoot/Glide.xcodeproj" \
        -scheme Debug \
        -configuration Debug \
        -derivedDataPath /private/tmp/GlideDerived \
        build
fi

exec /usr/bin/xcodebuild "$@"
