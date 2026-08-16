#!/usr/bin/env bash

set -eu

projectRoot=$(cd "$(dirname "$0")/../.." && pwd)
keychainPath="${HOME}/Library/Keychains/GlideDevelopment.keychain-db"
supportDirectory="${HOME}/Library/Application Support/GlideDevelopment"
passwordFile="${supportDirectory}/keychain-password"
opensslBin=$(command -v openssl)

/usr/bin/install -d -m 700 "$supportDirectory"
if [[ ! -f "$passwordFile" ]]; then
    "$opensslBin" rand -hex -out "$passwordFile" 32
    /bin/chmod 600 "$passwordFile"
fi
keychainPassword=$(/usr/bin/tr -d '\n' < "$passwordFile")

if [[ ! -f "$keychainPath" ]]; then
    /usr/bin/security create-keychain -p "$keychainPassword" "$keychainPath"
fi
/usr/bin/security set-keychain-settings "$keychainPath"
/usr/bin/security unlock-keychain -p "$keychainPassword" "$keychainPath"

keychainAlreadyListed=false
keychains=()
while IFS= read -r keychain; do
    keychain=$(printf '%s' "$keychain" | /usr/bin/sed -E 's/^[[:space:]]*"(.*)"$/\1/')
    [[ -z "$keychain" ]] && continue
    keychains+=("$keychain")
    [[ "$keychain" == "$keychainPath" ]] && keychainAlreadyListed=true
done < <(/usr/bin/security list-keychains -d user)
if [[ "$keychainAlreadyListed" == false ]]; then
    keychains+=("$keychainPath")
    /usr/bin/security list-keychains -d user -s "${keychains[@]}"
fi

if ! /usr/bin/security find-identity -v -p codesigning "$keychainPath" | /usr/bin/grep -q '"Local Self-Signed"'; then
    certificateDirectory=$(/usr/bin/mktemp -d /private/tmp/glide-codesign.XXXXXX)
    trap '/bin/rm -rf -- "$certificateDirectory"' EXIT
    certificateFile="${certificateDirectory}/codesign"

    "$projectRoot/scripts/codesign/generate_selfsigned_certificate.sh" "$certificateFile" "$keychainPassword"
    /usr/bin/security import "$certificateFile.p12" -k "$keychainPath" -P "$keychainPassword" -x -T /usr/bin/codesign
    /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$keychainPassword" "$keychainPath"
    /usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$keychainPath" "$certificateFile.crt"
fi

/usr/bin/security find-identity -v -p codesigning "$keychainPath"
