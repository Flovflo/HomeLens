#!/usr/bin/env bash
# Store Apple notarization credentials in the Keychain as a notarytool profile,
# so release.sh can notarize non-interactively. Run this once.
#
# It launches `xcrun notarytool store-credentials`, which prompts you securely.
# You'll need EITHER:
#   A) App Store Connect API key (recommended): Issuer ID, Key ID, path to the
#      AuthKey_XXXX.p8 file. Create at https://appstoreconnect.apple.com
#      -> Users and Access -> Integrations -> App Store Connect API.
#   B) Apple ID: your Apple ID email, Team ID, and an app-specific password
#      from https://appleid.apple.com -> Sign-In and Security.
#
# Nothing is written to the repo — credentials live only in your Keychain.
set -euo pipefail
PROFILE="${1:-homelens-notary}"

echo "Storing notarization credentials under Keychain profile: $PROFILE"
echo "Follow the prompts (choose the API key method if you have one)."
echo
xcrun notarytool store-credentials "$PROFILE"
echo
echo "Done. Verify with:  xcrun notarytool history --keychain-profile $PROFILE"
