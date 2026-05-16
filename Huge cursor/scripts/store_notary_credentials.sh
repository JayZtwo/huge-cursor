#!/usr/bin/env bash
set -euo pipefail

PROFILE="${1:-shake-cursor-notary}"

echo "Storing notary credentials in keychain profile: $PROFILE"
echo
echo "Recommended API key form:"
echo "  xcrun notarytool store-credentials \"$PROFILE\" --key /path/AuthKey_XXXXXXXXXX.p8 --key-id KEY_ID --issuer ISSUER_ID"
echo
echo "Apple ID form:"
echo "  xcrun notarytool store-credentials \"$PROFILE\" --apple-id name@example.com --team-id TEAM_ID --password APP_SPECIFIC_PASSWORD"
echo
xcrun notarytool store-credentials "$PROFILE"
