#!/bin/bash
#
# upload-appstore.sh - archive Aetherfield and upload it to App Store Connect.
#
# Archives the AirGradientMonitor scheme for iOS (iPhone + iPad), exports it with App Store
# distribution signing, and uploads it with an App Store Connect API key. Once processed
# (usually 5-30 min), the build shows up in TestFlight, ready to test or submit.
#
# Adapted from Glass Bead Game III's scripts/upload-appstore.sh; the same API key serves both.
#
# Run it from a session that can sign: Terminal.app, or an SSH session after unlocking the
# login keychain (the script offers to do that). Claude Code's own shell can't sign.
#
# ONE-TIME SETUP (the API key is optional: without ASC_KEY_ID set, the Apple ID signed in to
# Xcode > Settings > Accounts is used instead, which works when running on the Mac itself)
#   1. Signing.local.xcconfig (gitignored) must set DEVELOPMENT_TEAM and
#      PRODUCT_BUNDLE_IDENTIFIER = com.sohl.aetherfield. The script refuses the
#      com.example placeholder.
#   2. App Store Connect > Apps > + New App: iOS, name "Aetherfield", bundle ID
#      com.sohl.aetherfield (register it first under Certificates, Identifiers & Profiles if
#      it isn't offered), SKU e.g. aetherfield.
#   3. App Store Connect API key: the same Admin-role Team key and ASC_KEY_ID / ASC_ISSUER_ID
#      as Glass Bead Game III (see that script's ONE-TIME SETUP). Admin because this Mac has
#      only an Apple Development certificate, so export uses cloud-managed distribution
#      signing.
#
# USAGE
#   scripts/upload-appstore.sh [--build N] [--dry-run] [--no-unlock]
#
#   --build      Build number (CFBundleVersion). Default: the git commit count.
#   --dry-run    Archive and export locally, don't upload (needs a local Distribution cert).
#   --no-unlock  Skip the keychain unlock prompt.
#
# Output goes to build/release/<build>/ (archive, exported .ipa, logs).

set -euo pipefail

SCHEME="AirGradientMonitor"
PROJECT="AirGradientMonitor.xcodeproj"

BUILD_NUMBER=""
DRY_RUN=0
UNLOCK=1

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD_NUMBER="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-unlock) UNLOCK=0; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

# Always run from the repo root, wherever the script was called from.
cd "$(dirname "$0")/.."
[[ -d "$PROJECT" ]] || die "can't find $PROJECT - run from inside the repo"

BUNDLE_ID="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *PRODUCT_BUNDLE_IDENTIFIER = /{print $2; exit}')"
[[ "$BUNDLE_ID" == com.example.* || -z "$BUNDLE_ID" ]] && \
    die "bundle ID is '$BUNDLE_ID' - set it in Signing.local.xcconfig (see ONE-TIME SETUP)"

# --- Preflight -------------------------------------------------------------------------------

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "warning: uncommitted changes to tracked files - the upload will include them," >&2
    echo "         but they won't be in git. Commit first to keep builds reproducible." >&2
    read -r -p "Continue anyway? [y/N] " answer
    [[ "$answer" == [yY]* ]] || exit 1
fi

[[ -n "$BUILD_NUMBER" ]] || BUILD_NUMBER="$(git rev-list --count HEAD)"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "--build must be a whole number"

AUTH_ARGS=()
if [[ -z "${ASC_KEY_ID:-}" ]]; then
    # No API key: xcodebuild falls back to the Apple ID signed in to Xcode > Settings >
    # Accounts, which can do cloud-managed distribution signing and the upload itself.
    echo "No ASC_KEY_ID set - signing and uploading with the account signed in to Xcode."
else
    [[ -n "${ASC_ISSUER_ID:-}" ]] || die "ASC_ISSUER_ID not set (see ONE-TIME SETUP in this script)"
    ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
    [[ -f "$ASC_KEY_PATH" ]] || die "API key not found at $ASC_KEY_PATH"
    AUTH_ARGS=(-authenticationKeyPath "$ASC_KEY_PATH"
               -authenticationKeyID "$ASC_KEY_ID"
               -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

# Signing needs the login keychain unlocked in *this* session - over SSH it usually isn't,
# which shows up as "errSecInternalComponent" at the CodeSign step.
if [[ $UNLOCK -eq 1 ]]; then
    echo "Unlocking the login keychain for signing (your Mac login password):"
    security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"
fi

OUT="build/release/$BUILD_NUMBER"
mkdir -p "$OUT"

VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *MARKETING_VERSION = /{print $2; exit}')"
echo
echo "Aetherfield $VERSION (build $BUILD_NUMBER) - $BUNDLE_ID"
[[ $DRY_RUN -eq 1 ]] && echo "Dry run: archive and export only, no upload."
echo "Output: $OUT"
echo

# --- Archive, export, upload -----------------------------------------------------------------

# destination=upload makes -exportArchive send the build straight to App Store Connect;
# "export" just writes the signed .ipa/.pkg locally (dry run).
EXPORT_PLIST="$OUT/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$([[ $DRY_RUN -eq 1 ]] && echo export || echo upload)</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>342G7AUKSH</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
PLIST

run_logged() {
    # Runs a command with full output in a log file and only the useful lines on screen.
    local log="$1"; shift
    if "$@" > "$log" 2>&1; then
        grep -E 'SUCCEEDED|Uploaded|Exported|Progress' "$log" | tail -3 || true
    else
        grep -E 'error:|errSec|FAILED|No profiles|No signing certificate|Error Domain' "$log" | head -20 >&2 || true
        die "failed - full log: $log"
    fi
}

archive="$OUT/Aetherfield.xcarchive"

echo "== archiving"
run_logged "$OUT/archive.log" \
    xcodebuild archive \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -destination "generic/platform=iOS" -archivePath "$archive" \
        -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

echo "== $([[ $DRY_RUN -eq 1 ]] && echo exporting || echo 'exporting and uploading')"
run_logged "$OUT/export.log" \
    xcodebuild -exportArchive \
        -archivePath "$archive" -exportPath "$OUT/export" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
echo

if [[ $DRY_RUN -eq 1 ]]; then
    echo "Done. Signed build is in $OUT/export/ - nothing was uploaded."
else
    echo "Done. Build $BUILD_NUMBER is uploaded."
    echo "App Store Connect emails you when processing finishes; it then appears in TestFlight."
fi
