#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s TEAM_ID NOTARY_KEYCHAIN_PROFILE OUTPUT_DIRECTORY\n' "$0" >&2
    exit 2
}

[[ $# -eq 3 ]] || usage
team_id="$1"
notary_profile="$2"
output_dir="$3"
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
feed_url="${DEVWORKSPACE_UPDATE_FEED_URL:-}"
public_key="${DEVWORKSPACE_UPDATE_PUBLIC_KEY:-}"

[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || usage
[[ -n "$notary_profile" && "$output_dir" = /* ]] || usage
[[ "$feed_url" =~ ^https://[^/@?#]+(/[^?#]*)?$ && "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
    printf 'Set the HTTPS DEVWORKSPACE_UPDATE_FEED_URL and EdDSA DEVWORKSPACE_UPDATE_PUBLIC_KEY before release.\n' >&2
    exit 2
}
[[ ! -e "$output_dir" ]] || { printf 'Output directory already exists: %s\n' "$output_dir" >&2; exit 2; }
[[ -z "$(git -C "$source_dir" status --porcelain)" ]] || {
    printf 'Commit or stash repository changes before creating a release.\n' >&2
    exit 2
}

identity="$(security find-identity -v -p codesigning | /usr/bin/grep -F "Developer ID Application:" | /usr/bin/grep -F "($team_id)" | /usr/bin/head -n 1 || true)"
[[ -n "$identity" ]] || {
    printf 'No valid Developer ID Application identity for team %s is installed.\n' "$team_id" >&2
    exit 2
}

mkdir -p "$output_dir"
archive="$output_dir/DevWorkspace.xcarchive"
export_dir="$output_dir/export"
derived_data="$output_dir/DerivedData"

# Archive and export with Xcode so embedded code and entitlements are signed as a unit.
xcodebuild -quiet \
    -project "$source_dir/DevWorkspace.xcodeproj" \
    -scheme DevWorkspace \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    -archivePath "$archive" \
    "DEVELOPMENT_TEAM=$team_id" \
    "DEVWORKSPACE_UPDATE_FEED_URL=$feed_url" \
    "DEVWORKSPACE_UPDATE_PUBLIC_KEY=$public_key" \
    'CODE_SIGN_STYLE=Manual' \
    'CODE_SIGN_IDENTITY=Developer ID Application' \
    archive

xcodebuild -quiet -exportArchive \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$source_dir/release/ExportOptions.plist"

app="$export_dir/DevWorkspace.app"
[[ -d "$app" ]] || { printf 'Exported app is missing.\n' >&2; exit 1; }
[[ -f "$app/Contents/Resources/Sparkle-LICENSE.txt" ]] || {
    printf 'Sparkle license notices are missing from the exported app.\n' >&2
    exit 1
}
info_plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist")" == "$feed_url" ]] || {
    printf 'Exported app has an unexpected update feed.\n' >&2
    exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist")" == "$public_key" ]] || {
    printf 'Exported app has an unexpected update signing key.\n' >&2
    exit 1
}
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
signature_info="$(/usr/bin/codesign -dvv "$app" 2>&1)"
[[ "$signature_info" == *"Identifier=com.zhaobinrui.devspace.workspace"* ]] || {
    printf 'Export changed the expected Bundle Identifier.\n' >&2
    exit 1
}
[[ "$signature_info" == *"TeamIdentifier=$team_id"* ]] || {
    printf 'Export was not signed by the selected Developer ID team.\n' >&2
    exit 1
}

submission_zip="$output_dir/DevWorkspace-for-notarization.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$submission_zip"
xcrun notarytool submit "$submission_zip" --keychain-profile "$notary_profile" --wait --timeout 30m
xcrun stapler staple "$app"
xcrun stapler validate "$app"
/usr/sbin/spctl --assess --type execute --verbose "$app"

# Zip again after stapling; the submitted zip predates the attached ticket.
release_zip="$output_dir/DevWorkspace-notarized.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$release_zip"
/usr/bin/shasum -a 256 "$release_zip"
printf 'Release artifact: %s\n' "$release_zip"
