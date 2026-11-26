#!/bin/bash
# Build and upload matching TestFlight archives and Sentry debug symbols.
set +x
set -euo pipefail
umask 077

sentry_auth_token=${SENTRY_AUTH_TOKEN:-}
unset CDPATH SENTRY_AUTH_TOKEN

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$root_dir/PartyBox.xcodeproj"

usage() {
    cat <<'USAGE'
Usage:
  scripts/distribute.sh --build-number N [--platform all|ios|tvos|macos] [--archive-only]
  scripts/distribute.sh --resume RUN_DIR [--platform ios|tvos|macos] [--retry-apple-upload]

Requires APPLE_TEAM_ID and SENTRY_DSN. Uploads also require SENTRY_ORG,
SENTRY_PROJECT, SENTRY_AUTH_TOKEN, and sentry-cli. See docs/RELEASE.md.
USAGE
}

die() {
    printf 'distribute: %s\n' "$*" >&2
    exit 1
}

require_value() {
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 requires a value."
}

require_tool() {
    command -v "$1" >/dev/null || die "Required tool not found: $1"
}

run_xcodebuild() {
    local log=$1
    shift
    (umask 022; xcodebuild "$@") 2>&1 | tee -a "$log"
}

plist_value() {
    plutil -extract "$1" raw -o - "$2"
}

platform_settings() {
    case "$1" in
        ios)
            scheme="PartyBox Controller"
            destination="iOS"
            supported_platform="iPhoneOS"
            bundle_contents=""
            ;;
        tvos)
            scheme="PartyBox"
            destination="tvOS"
            supported_platform="AppleTVOS"
            bundle_contents=""
            ;;
        macos)
            scheme="PartyBox"
            destination="macOS"
            supported_platform="MacOSX"
            bundle_contents="/Contents"
            ;;
    esac
}

archive_platform() {
    local platform=$1 archive_dir="$run_dir/$1"
    platform_settings "$platform"
    mkdir -p "$archive_dir"
    printf 'Archiving %s (%s)\n' "$scheme" "$platform"

    run_xcodebuild "$archive_dir/archive.log" \
        -project "$project" -scheme "$scheme" -configuration Release \
        -destination "generic/platform=$destination" -archivePath "$archive_dir/app.xcarchive" \
        -onlyUsePackageVersionsFromResolvedFile -allowProvisioningUpdates \
        "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" "CURRENT_PROJECT_VERSION=$build_number" \
        "PARTYBOX_SENTRY_DSN=$SENTRY_DSN" PARTYBOX_SENTRY_ENVIRONMENT=testflight archive \
        || die "$platform archive failed. See $archive_dir/archive.log"
}

mach_uuids() {
    xcrun dwarfdump --uuid "$1" | awk '/^UUID: / { print $2, $3 }' | sort
}

lock_release_directory() {
    local lock_path="$run_dir/.lock" result=0
    if [[ -d "$lock_path" ]]; then
        die "Release directory has a legacy lock: $run_dir. See docs/RELEASE.md for stale lock recovery."
    fi
    # Keep the file and descriptor open for the lifetime of the run and its children.
    exec 9>>"$lock_path"
    case "$OSTYPE" in
        darwin*) lockf -s -t 0 9 || result=$? ;;
        linux*) flock -n -E 75 9 || result=$? ;;
    esac
    if [[ $result -eq 75 ]]; then
        die "Release directory is in use: $run_dir. Wait for the active script and its upload processes to finish."
    fi
    [[ $result -eq 0 ]] || die "Could not lock the release directory: $run_dir"
}

validate_macos_permissions() {
    local app=$1 invalid
    invalid="$(find "$app" \( -type f ! -perm -444 -o -type d ! -perm -111 \) -print)" \
        || die "Could not check macOS archive permissions at $app. Rebuild the archive."
    [[ -z "$invalid" ]] || die "macOS archive has unreadable files or untraversable directories. Rebuild the archive. First affected path: ${invalid%%$'\n'*}"
}

validate_archive() {
    local platform=$1 archive="$run_dir/$1/app.xcarchive"
    local app info executable binary symbols app_uuids symbol_uuids sentry_environment
    platform_settings "$platform"

    app="$archive/Products/Applications/$scheme.app"
    info="$app$bundle_contents/Info.plist"
    [[ -f "$info" ]] || die "$platform archive is missing its application Info.plist."
    [[ "$(plist_value CFBundleSupportedPlatforms.0 "$info")" == "$supported_platform" ]] \
        || die "$platform archive has the wrong supported platform."
    [[ "$(plist_value CFBundleVersion "$info")" == "$build_number" ]] \
        || die "$platform archive has the wrong build number."
    [[ "$(plist_value PartyBoxSentryDSN "$info")" == "$SENTRY_DSN" ]] \
        || die "$platform archive has a missing or different Sentry DSN."
    if sentry_environment="$(plist_value PartyBoxSentryEnvironment "$info" 2>/dev/null)"; then
        [[ "$sentry_environment" == testflight ]] || die "$platform archive has the wrong Sentry environment."
    elif [[ -z "$resume_dir" ]]; then
        die "$platform archive is missing its Sentry environment."
    else
        printf 'distribute: warning: %s legacy archive is missing its Sentry environment.\n' "$platform" >&2
    fi

    executable="$(plist_value CFBundleExecutable "$info")" \
        || die "$platform archive is missing CFBundleExecutable."
    [[ -n "$executable" && "$executable" != */* ]] || die "$platform has an invalid executable name."
    binary="$app$bundle_contents/$executable"
    if [[ "$platform" == macos ]]; then
        binary="$app/Contents/MacOS/$executable"
    fi
    symbols="$archive/dSYMs/$scheme.app.dSYM/Contents/Resources/DWARF/$executable"

    [[ -f "$binary" && -f "$symbols" ]] || die "$platform archive is missing its app binary or dSYM."
    app_uuids="$(mach_uuids "$binary")" || die "Could not read $platform app UUIDs."
    symbol_uuids="$(mach_uuids "$symbols")" || die "Could not read $platform dSYM UUIDs."
    [[ -n "$app_uuids" && "$app_uuids" == "$symbol_uuids" ]] \
        || die "$platform app and dSYM UUIDs do not match."
    if [[ "$platform" == macos && ! -f "$run_dir/macos/apple-uploaded" ]]; then
        validate_macos_permissions "$app"
    fi
}

upload_symbols() {
    local archive_dir="$run_dir/$1"
    printf 'Uploading %s debug symbols to Sentry\n' "$1"
    SENTRY_AUTH_TOKEN="$sentry_auth_token" SENTRY_ALLOW_FAILURE=0 sentry-cli debug-files upload --wait \
        --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" "$archive_dir/app.xcarchive/dSYMs" \
        2>&1 | tee -a "$archive_dir/sentry.log" \
        || die "$1 symbol upload failed. See $archive_dir/sentry.log"
}

upload_apple() {
    local archive_dir="$run_dir/$1" attempt_dir
    attempt_dir="$(mktemp -d "$archive_dir/apple-attempt.XXXXXXXX")"
    printf 'Uploading %s build %s to App Store Connect\n' "$1" "$build_number"
    date -u > "$archive_dir/apple-upload-started"
    run_xcodebuild "$archive_dir/apple.log" -exportArchive \
        -archivePath "$archive_dir/app.xcarchive" \
        -exportOptionsPlist "$run_dir/ExportOptions.plist" \
        -exportPath "$attempt_dir/export" -allowProvisioningUpdates \
        || die "$1 Apple upload did not confirm delivery. Check $archive_dir/apple.log and App Store Connect before retrying."
    date -u >> "$archive_dir/apple-upload-started"
    mv "$archive_dir/apple-upload-started" "$archive_dir/apple-uploaded"
    printf 'Apple accepted the %s upload for processing.\n' "$1"
}

build_number=""
platform=all
archive_only=false
resume_dir=""
retry_apple=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --build-number) require_value "$@"; build_number=$2; shift ;;
        --platform) require_value "$@"; platform=$2; shift ;;
        --archive-only) archive_only=true ;;
        --resume) require_value "$@"; resume_dir=$2; shift ;;
        --retry-apple-upload) retry_apple=true ;;
        *) die "Unknown argument: $1. Use --help for usage." ;;
    esac
    shift
done

case "$platform" in
    all|ios|tvos|macos) ;;
    *) die "Unknown platform: $platform" ;;
esac

if [[ -n "$resume_dir" ]]; then
    [[ -z "$build_number" && "$archive_only" == false ]] \
        || die "--resume already has a build number and cannot be combined with --archive-only."
    run_dir="$(cd -- "$resume_dir" && pwd -P)" || die "Release directory not found: $resume_dir"
    [[ -f "$run_dir/archives-ready" ]] || die "Release directory has no completed archive set."
else
    [[ "$build_number" =~ ^[1-9][0-9]*$ ]] || die "--build-number must be a positive integer."
fi

if [[ "$retry_apple" == true && ( -z "$resume_dir" || "$platform" == all ) ]]; then
    die "--retry-apple-upload requires --resume and one platform."
fi

[[ "${APPLE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || die "Set APPLE_TEAM_ID to the 10-character signing team ID."
dsn_pattern='^https://[[:alnum:]]+@[^[:space:]/@?#]+(/[^[:space:]/?#]+)*/[0-9]+$'
[[ "${SENTRY_DSN:-}" =~ $dsn_pattern ]] || die "Set SENTRY_DSN to the shared project's public HTTPS DSN."
require_tool xcodebuild
require_tool xcrun
require_tool plutil
case "$OSTYPE" in
    darwin*) require_tool lockf ;;
    linux*) require_tool flock ;;
    *) die "Release directory locking requires macOS or Linux." ;;
esac

if [[ "$archive_only" == false ]]; then
    [[ -n "${SENTRY_ORG:-}" && -n "${SENTRY_PROJECT:-}" && -n "$sentry_auth_token" ]] \
        || die "Set SENTRY_ORG, SENTRY_PROJECT, and SENTRY_AUTH_TOKEN before uploading."
    require_tool sentry-cli
fi

if [[ -n "$resume_dir" ]]; then
    {
        if ! IFS= read -r build_number || ! IFS= read -r archived_team; then
            die "Release directory metadata is incomplete."
        fi
        [[ "$build_number" =~ ^[1-9][0-9]*$ && "$archived_team" == "$APPLE_TEAM_ID" ]] \
            || die "Release directory has an invalid build number or was archived for a different Apple team."
        archived_platforms=()
        while IFS= read -r archived_platform; do
            case "$archived_platform" in
                ios|tvos|macos) archived_platforms+=("$archived_platform") ;;
                *) die "Invalid platform in release directory metadata." ;;
            esac
        done
    } < "$run_dir/archives-ready"
    [[ "${#archived_platforms[@]}" -gt 0 ]] || die "Release directory declares no platforms."
    if [[ "$platform" == all ]]; then
        platforms=("${archived_platforms[@]}")
    else
        [[ " ${archived_platforms[*]} " == *" $platform "* ]] || die "No $platform archive in this release."
        platforms=("$platform")
    fi
else
    if [[ "$platform" == all ]]; then
        platforms=(ios tvos macos)
    else
        platforms=("$platform")
    fi
    mkdir -p "$root_dir/.distribution"
    run_dir="$(mktemp -d "$root_dir/.distribution/build-$build_number.XXXXXXXX")"
fi

lock_release_directory
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'Release artifacts: %s\n' "$run_dir"

if [[ -z "$resume_dir" ]]; then
    for platform in "${platforms[@]}"; do
        archive_platform "$platform"
    done
fi
for platform in "${platforms[@]}"; do
    validate_archive "$platform"
done

if [[ -z "$resume_dir" ]]; then
    printf '%s\n' "$build_number" "$APPLE_TEAM_ID" "${platforms[@]}" > "$run_dir/archives-ready"
fi
if [[ "$archive_only" == true ]]; then
    printf 'Validated archives for build %s. Resume with --resume "%s".\n' "$build_number" "$run_dir"
    exit 0
fi

pending_platforms=()
for platform in "${platforms[@]}"; do
    if [[ -f "$run_dir/$platform/apple-uploaded" ]]; then
        printf '%s build %s already has an Apple upload receipt.\n' "$platform" "$build_number"
        continue
    fi
    if [[ -f "$run_dir/$platform/apple-upload-started" && "$retry_apple" == false ]]; then
        die "$platform has an unconfirmed Apple upload. Check App Store Connect before retrying; see docs/RELEASE.md."
    fi
    pending_platforms+=("$platform")
done
[[ "${#pending_platforms[@]}" -gt 0 ]] || exit 0

for platform in "${pending_platforms[@]}"; do
    upload_symbols "$platform"
done

cat > "$run_dir/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>$APPLE_TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>testFlightInternalTestingOnly</key><false/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

for platform in "${pending_platforms[@]}"; do
    upload_apple "$platform"
done
printf 'Build %s uploads complete. Check TestFlight in App Store Connect for processing status.\n' "$build_number"
