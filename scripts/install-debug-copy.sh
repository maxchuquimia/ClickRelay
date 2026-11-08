#!/bin/sh
# Debug only: copies the built app to /Applications/ClickRelay.app, so the
# path registered with `claude mcp add` stays put while DerivedData moves.
#
# Xcode signs the product after the last build phase, so the copy is re-signed
# here with the same identity and entitlements. Permissions follow the
# designated requirement (team + bundle ID), not the path, so they carry over.
set -eu

[ "${CONFIGURATION}" = "Debug" ] || exit 0
# Test runs and previews build the app too; only install real builds.
[ "${ACTION:-build}" = "build" ] || [ "${ACTION:-build}" = "install" ] || exit 0

DEST="/Applications/${FULL_PRODUCT_NAME}"
rm -rf "${DEST}"
ditto "${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}" "${DEST}"
# Test runs embed the unit test bundle in the app; the installed copy doesn't need it.
rm -rf "${DEST}/Contents/PlugIns/"*.xctest
rmdir "${DEST}/Contents/PlugIns" 2>/dev/null || true

ENTITLEMENTS="${TARGET_TEMP_DIR}/${FULL_PRODUCT_NAME}.xcent"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "${IDENTITY}" ] || [ "${IDENTITY}" = "-" ]; then
    echo "warning: no signing identity; /Applications copy is unsigned and permissions won't stick."
    exit 0
fi
# Debug builds split the code into ClickRelay.debug.dylib (and a preview
# dylib); nested code has to be signed before the bundle around it.
find "${DEST}/Contents/MacOS" "${DEST}/Contents/Frameworks" -name '*.dylib' -type f 2>/dev/null |
while read -r LIB; do
    codesign --force --sign "${IDENTITY}" --options runtime --timestamp=none "${LIB}"
done
if [ -f "${ENTITLEMENTS}" ]; then
    codesign --force --sign "${IDENTITY}" --options runtime --timestamp=none \
        --entitlements "${ENTITLEMENTS}" --generate-entitlement-der "${DEST}"
else
    codesign --force --sign "${IDENTITY}" --options runtime --timestamp=none "${DEST}"
fi
echo "Installed ${DEST}"
