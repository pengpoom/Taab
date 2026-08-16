#!/usr/bin/env bash

set -eu

certificateFile="$1"
certificatePassword="$2"
loginKeychain=$(security default-keychain -d user | tr -d ' "\n')

# Import into the actual login keychain explicitly. Sandboxed/agent-driven
# shells can otherwise resolve a different default keychain and report success
# even though Xcode cannot see the identity afterwards. Keep private-key access
# scoped to Apple's codesign tool; never use `security import -A` here.
security import "$certificateFile.p12" -k "$loginKeychain" -P "$certificatePassword" -x -T /usr/bin/codesign
# in Keychain, set Trust > Code Signing > "Always Trust"
security add-trusted-cert -r trustRoot -p codeSign -k "$loginKeychain" "$certificateFile.crt"
