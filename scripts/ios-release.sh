#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# App Store Connect rejects archives produced by prerelease Xcode builds. Native development and
# Release archives and current Simulator verification default to the public Xcode 27 toolchain.
XCODE_APP="${BUDGET_APP_XCODE_APP:-/Applications/Xcode.app}"
DEVELOPER_DIR="${XCODE_APP}/Contents/Developer"
PROJECT="${REPOSITORY_ROOT}/ios/BudgetApp.xcodeproj"
SCHEME="BudgetApp"
BUNDLE_ID="com.firepika.BudgetApp"
ACTION="${1:-preflight}"

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

[[ -d "${DEVELOPER_DIR}" ]] || fail "Xcode is not available at ${XCODE_APP}"
[[ -f "${PROJECT}/project.pbxproj" ]] || fail "BudgetApp.xcodeproj is missing"
[[ "${ACTION}" == "preflight" || "${ACTION}" == "archive" ]] || fail "usage: scripts/ios-release.sh [preflight|archive]"

export DEVELOPER_DIR
printf 'Xcode: %s\n' "${XCODE_APP}"
xcodebuild -version

TEAM_ID="${BUDGET_APP_DEVELOPMENT_TEAM:-}"
if [[ -z "${TEAM_ID}" ]]; then
    fail "Set BUDGET_APP_DEVELOPMENT_TEAM to the 10-character Apple Developer Team ID"
fi
if [[ ! "${TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]]; then
    fail "BUDGET_APP_DEVELOPMENT_TEAM must be a 10-character Apple Team ID"
fi

# Dropbox uses a public OAuth client identifier with PKCE; no client secret is embedded. Requiring
# the registered key at release time prevents a valid-looking archive from silently shipping the
# otherwise complete backup destination in its fail-closed, unavailable state.
DROPBOX_APP_KEY="${BUDGET_APP_DROPBOX_APP_KEY:-}"
if [[ -z "${DROPBOX_APP_KEY}" ]]; then
    fail "Set BUDGET_APP_DROPBOX_APP_KEY to ClearPocket's registered Dropbox app key"
fi
if [[ ! "${DROPBOX_APP_KEY}" =~ ^[A-Za-z0-9_-]{8,128}$ ]]; then
    fail "BUDGET_APP_DROPBOX_APP_KEY has an invalid format"
fi

IDENTITIES="$(security find-identity -v -p codesigning 2>&1 || true)"
printf '%s\n' "${IDENTITIES}"
if grep -q '0 valid identities found' <<<"${IDENTITIES}"; then
    fail "No Apple code-signing identity is installed; open Xcode Settings > Accounts first"
fi

BUILD_SETTINGS="$(xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -configuration Release -showBuildSettings DEVELOPMENT_TEAM="${TEAM_ID}" DROPBOX_APP_KEY="${DROPBOX_APP_KEY}")"
ACTUAL_BUNDLE_ID="$(awk -F ' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = / { print $2; exit }' <<<"${BUILD_SETTINGS}")"
ACTUAL_TEAM="$(awk -F ' = ' '/^[[:space:]]*DEVELOPMENT_TEAM = / { print $2; exit }' <<<"${BUILD_SETTINGS}")"
ACTUAL_VERSION="$(awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / { print $2; exit }' <<<"${BUILD_SETTINGS}")"
ACTUAL_BUILD="$(awk -F ' = ' '/^[[:space:]]*CURRENT_PROJECT_VERSION = / { print $2; exit }' <<<"${BUILD_SETTINGS}")"
ACTUAL_DROPBOX_APP_KEY="$(awk -F ' = ' '/^[[:space:]]*DROPBOX_APP_KEY = / { print $2; exit }' <<<"${BUILD_SETTINGS}")"

[[ "${ACTUAL_BUNDLE_ID}" == "${BUNDLE_ID}" ]] || fail "Expected ${BUNDLE_ID}, found ${ACTUAL_BUNDLE_ID:-unset}"
[[ "${ACTUAL_TEAM}" == "${TEAM_ID}" ]] || fail "Xcode did not apply the requested development team"
[[ -n "${ACTUAL_VERSION}" && -n "${ACTUAL_BUILD}" ]] || fail "Release version/build settings are missing"
[[ "${ACTUAL_DROPBOX_APP_KEY}" == "${DROPBOX_APP_KEY}" ]] || fail "Xcode did not inject the registered Dropbox app key"

printf 'Bundle ID: %s\nTeam: %s\nVersion: %s (%s)\n' "${ACTUAL_BUNDLE_ID}" "${ACTUAL_TEAM}" "${ACTUAL_VERSION}" "${ACTUAL_BUILD}"
printf 'Signing preflight passed.\n'

if [[ "${ACTION}" == "preflight" ]]; then
    exit 0
fi

ARCHIVE_ROOT="${BUDGET_APP_ARCHIVE_DIRECTORY:-${REPOSITORY_ROOT}/artifacts/archives}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE_PATH="${ARCHIVE_ROOT}/BudgetApp-${ACTUAL_VERSION}-${ACTUAL_BUILD}-${STAMP}.xcarchive"
mkdir -p "${ARCHIVE_ROOT}"
[[ ! -e "${ARCHIVE_PATH}" ]] || fail "Archive destination already exists: ${ARCHIVE_PATH}"

xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "${ARCHIVE_PATH}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    DROPBOX_APP_KEY="${DROPBOX_APP_KEY}" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates \
    clean archive

[[ -d "${ARCHIVE_PATH}" ]] || fail "Xcode reported success but no archive was produced"
ARCHIVED_INFO="${ARCHIVE_PATH}/Products/Applications/Budget App.app/Info.plist"
[[ -f "${ARCHIVED_INFO}" ]] || fail "Archived application Info.plist is missing"
ARCHIVED_DROPBOX_APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :ClearPocketDropboxAppKey' "${ARCHIVED_INFO}" 2>/dev/null || true)"
[[ "${ARCHIVED_DROPBOX_APP_KEY}" == "${DROPBOX_APP_KEY}" ]] || fail "Archive is missing the registered Dropbox app key"
printf 'Signed archive created: %s\n' "${ARCHIVE_PATH}"
printf 'Next: open this archive in Xcode Organizer, Validate App, then upload to closed TestFlight.\n'
