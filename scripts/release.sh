#!/bin/bash
# Builds a Release copy of ClickRelay, signs it with Developer ID, notarizes
# and staples it, and zips it. Used by .github/workflows/release.yml and
# runnable on your own Mac.
#
#   scripts/release.sh <version> [build-number]
#
# <version> is X.Y.Z or X.Y.Z-suffix. The bundle gets X.Y.Z as its version;
# the zip is named with the full string.
#
# Signing identity, one of:
#   DEVELOPER_ID_P12_BASE64 + DEVELOPER_ID_P12_PASSWORD
#       A base64 .p12 of the Developer ID Application certificate and key.
#       Imported into a throwaway keychain that is deleted on exit (CI).
#   (neither set)
#       Uses the Developer ID Application identity already in your keychains.
#
# Notarization credentials, one of:
#   NOTARY_KEY_P8_BASE64 + NOTARY_KEY_ID + NOTARY_ISSUER_ID
#       An App Store Connect API key (base64 .p8), its key ID and issuer ID.
#   NOTARY_KEYCHAIN_PROFILE
#       A profile saved with `xcrun notarytool store-credentials`.
#
# Output (OUTPUT_DIR, default build/release):
#   ClickRelay-<version>.zip, ClickRelay-<version>.zip.sha256
#
# Bash 3.2 compatible, since that's what macOS ships.
set -euo pipefail

TEAM_ID="D3NCG82LUC"
BUNDLE_ID="io.mergeable.ClickRelay"
APP_NAME="ClickRelay"

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[ $# -ge 1 ] || die "usage: $0 <version> [build-number]"
VERSION="$1"
BUILD_NUMBER="${2:-1}"
[[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z.-]+)?$ ]] ||
    die "version must look like 1.2.3 or 1.2.3-beta.1, got '$VERSION'"
MARKETING_VERSION="${BASH_REMATCH[1]}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "build number must be an integer, got '$BUILD_NUMBER'"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/build/release}"
ENTITLEMENTS="$ROOT/ClickRelay/ClickRelay.entitlements"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/clickrelay-release.XXXXXX")"
KEYCHAIN=""
ORIGINAL_KEYCHAINS=()

cleanup() {
    if [ -n "$KEYCHAIN" ]; then
        if [ ${#ORIGINAL_KEYCHAINS[@]} -gt 0 ]; then
            security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" || true
        fi
        security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- Notarization credentials ------------------------------------------------
NOTARY_ARGS=()
if [ -n "${NOTARY_KEY_P8_BASE64:-}" ]; then
    [ -n "${NOTARY_KEY_ID:-}" ] || die "NOTARY_KEY_ID is required with NOTARY_KEY_P8_BASE64"
    [ -n "${NOTARY_ISSUER_ID:-}" ] || die "NOTARY_ISSUER_ID is required with NOTARY_KEY_P8_BASE64"
    KEY_FILE="$WORK/AuthKey_${NOTARY_KEY_ID}.p8"
    (umask 077 && printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$KEY_FILE")
    NOTARY_ARGS=(--key "$KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
    die "no notarization credentials: set NOTARY_KEY_P8_BASE64, NOTARY_KEY_ID and NOTARY_ISSUER_ID, or NOTARY_KEYCHAIN_PROFILE"
fi

# --- Signing identity --------------------------------------------------------
if [ -n "${DEVELOPER_ID_P12_BASE64:-}" ]; then
    [ -n "${DEVELOPER_ID_P12_PASSWORD:-}" ] || die "DEVELOPER_ID_P12_PASSWORD is required with DEVELOPER_ID_P12_BASE64"
    step "Importing the signing certificate into a temporary keychain"
    KEYCHAIN="$WORK/signing.keychain-db"
    KEYCHAIN_PASSWORD="$(uuidgen)"
    P12="$WORK/cert.p12"
    (umask 077 && printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$P12")
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 3600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$P12" -k "$KEYCHAIN" -f pkcs12 -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    rm -f "$P12"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
        [ -n "$line" ] && ORIGINAL_KEYCHAINS+=("$line")
    done < <(security list-keychains -d user)
    # codesign --timestamp needs Apple's intermediate certificates, which live
    # in the system keychains; the user search list only needs ours added.
    security list-keychains -d user -s "$KEYCHAIN" ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"}
fi

IDENTITY="$(security find-identity -v -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} |
    awk -v team="($TEAM_ID)" 'index($0, "\"Developer ID Application: ") && index($0, team) { print $2; exit }')"
[ -n "$IDENTITY" ] || die "no valid 'Developer ID Application: … ($TEAM_ID)' identity found"
echo "Signing identity: $IDENTITY"
CODESIGN_KEYCHAIN_ARGS=()
[ -n "$KEYCHAIN" ] && CODESIGN_KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")

# --- Build -------------------------------------------------------------------
step "Building $APP_NAME $MARKETING_VERSION ($BUILD_NUMBER), Release"
xcodebuild -version
cd "$ROOT"
# Built unsigned, then signed below with codesign, so every flag that goes
# into the shipped signature is in this file.
xcodebuild \
    -project ClickRelay.xcodeproj \
    -target "$APP_NAME" \
    -configuration Release \
    SYMROOT="$WORK/build" \
    OBJROOT="$WORK/obj" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build

APP="$WORK/build/Release/$APP_NAME.app"
[ -d "$APP" ] || die "build finished but $APP is missing"
PLIST="$APP/Contents/Info.plist"
[ "$(plutil -extract CFBundleIdentifier raw "$PLIST")" = "$BUNDLE_ID" ] || die "unexpected bundle identifier"
[ "$(plutil -extract CFBundleShortVersionString raw "$PLIST")" = "$MARKETING_VERSION" ] || die "bundle version doesn't match $MARKETING_VERSION"
rm -rf "$APP/Contents/PlugIns/"*.xctest
rmdir "$APP/Contents/PlugIns" 2>/dev/null || true

# --- Sign --------------------------------------------------------------------
step "Signing with Developer ID, Hardened Runtime and a secure timestamp"
sign() {
    codesign --force --sign "$IDENTITY" "${CODESIGN_KEYCHAIN_ARGS[@]+"${CODESIGN_KEYCHAIN_ARGS[@]}"}" \
        --options runtime --timestamp "$@"
}
# Nested code first, deepest first, then the bundle around it.
NESTED="$WORK/nested.txt"
find "$APP/Contents" -mindepth 2 \
    \( -name '*.dylib' -o -name '*.framework' -o -name '*.bundle' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) \
    -print |
    awk '{ print gsub("/", "/"), $0 }' | sort -rn | cut -d' ' -f2- > "$NESTED"
while IFS= read -r item; do
    [ -n "$item" ] && sign "$item"
done < "$NESTED"
sign --entitlements "$ENTITLEMENTS" "$APP"

step "Checking the signature"
codesign --verify --strict --deep --verbose=2 "$APP"
SIG_INFO="$(codesign -dvvv "$APP" 2>&1)"
echo "$SIG_INFO" | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)'
echo "$SIG_INFO" | grep -q "^TeamIdentifier=$TEAM_ID\$" || die "signature isn't from team $TEAM_ID"
echo "$SIG_INFO" | grep -q "^Authority=Developer ID Application: " || die "signature isn't Developer ID"
echo "$SIG_INFO" | grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' || die "Hardened Runtime is off"
echo "$SIG_INFO" | grep -q '^Timestamp=' || die "signature has no secure timestamp"
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q 'get-task-allow'; then
    die "signature carries get-task-allow; notarization would reject it"
fi

# --- Notarize ----------------------------------------------------------------
step "Submitting to Apple's notary service (this usually takes a few minutes)"
SUBMIT_ZIP="$WORK/submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
SUBMIT_JSON="$WORK/submit.json"
NOTARY_RC=0
xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_ARGS[@]}" --wait --timeout 45m \
    --output-format json > "$SUBMIT_JSON" || NOTARY_RC=$?
cat "$SUBMIT_JSON"; echo
SUBMISSION_ID="$(plutil -extract id raw "$SUBMIT_JSON" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw "$SUBMIT_JSON" 2>/dev/null || true)"
if [ -n "$SUBMISSION_ID" ]; then
    # The log lists any warnings even when the submission is accepted.
    xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" || true
fi
[ "$STATUS" = "Accepted" ] || die "notarization status '${STATUS:-unknown}' (notarytool exit $NOTARY_RC)"

step "Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tee "$WORK/spctl.txt"
grep -q 'source=Notarized Developer ID' "$WORK/spctl.txt" || die "Gatekeeper doesn't see a notarized Developer ID app"

# --- Package -----------------------------------------------------------------
step "Packaging"
mkdir -p "$OUTPUT_DIR"
ZIP_NAME="$APP_NAME-$VERSION.zip"
rm -f "$OUTPUT_DIR/$ZIP_NAME" "$OUTPUT_DIR/$ZIP_NAME.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/$ZIP_NAME"
(cd "$OUTPUT_DIR" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256" && cat "$ZIP_NAME.sha256")
echo "Done: $OUTPUT_DIR/$ZIP_NAME"
