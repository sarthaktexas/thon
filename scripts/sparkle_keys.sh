#!/bin/bash
# One-time: create the EdDSA signing key pair for updates and write the public half into Info.plist.
# The PRIVATE key goes in your login Keychain (item "https://sparkle-project.org"). Back it up with
#   .build/artifacts/.../generate_keys -x thon_sparkle_private_key   (store it somewhere safe, never in git).
# If it is lost, installed copies of Thon can never be updated again.
set -euo pipefail
cd "$(dirname "$0")/.."
swift package resolve
GEN="$(find .build/artifacts -type f -name generate_keys | head -1)"
[[ -x "$GEN" ]] || { echo "generate_keys not found under .build/artifacts" >&2; exit 1; }
"$GEN" >/dev/null || true                      # creates the key if there is none yet
PUB="$("$GEN" -p)"                             # prints the public key
[[ -n "$PUB" ]] || { echo "could not read the public key" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUB" Resources/Info.plist
echo "SUPublicEDKey set in Resources/Info.plist: $PUB"
echo "Commit Resources/Info.plist, then run scripts/release.sh <version>."
