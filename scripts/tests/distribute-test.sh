#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

checkout="$tmp_dir/checkout with spaces"
mkdir -p "$checkout/scripts" "$tmp_dir/bin"
cp "$root_dir/scripts/distribute.sh" "$checkout/scripts/"
script="$checkout/scripts/distribute.sh"
output="$tmp_dir/output"
calls="$tmp_dir/calls"
: > "$calls"

cat > "$tmp_dir/bin/distribution-stub" <<'STUB'
#!/bin/bash
set -euo pipefail
tool="${0##*/}"

case "$tool" in
    xcodebuild)
        # The Sentry credential must be absent even from Xcode's process environment.
        [[ -z "${SENTRY_AUTH_TOKEN+x}" ]]
        archive=""
        export_plist=""
        exporting=false
        scheme=""
        build=""
        dsn=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -exportArchive) exporting=true ;;
                -archivePath) archive=$2; shift ;;
                -exportOptionsPlist) export_plist=$2; shift ;;
                -scheme) scheme=$2; shift ;;
                CURRENT_PROJECT_VERSION=*) build="${1#*=}" ;;
                PARTYBOX_SENTRY_DSN=*) dsn="${1#*=}" ;;
            esac
            shift
        done
        platform_dir="${archive%/*}"
        platform="${platform_dir##*/}"
        if [[ "$exporting" == true ]]; then
            grep -q 'destination</key><string>upload' "$export_plist"
            grep -q 'method</key><string>app-store-connect' "$export_plist"
            grep -q 'manageAppVersionAndBuildNumber</key><false' "$export_plist"
            printf 'apple %s\n' "$platform" >> "$STUB_CALLS"
            [[ "$platform" != "${STUB_FAIL_APPLE:-}" ]]
            exit
        fi

        printf 'archive %s\n' "$platform" >> "$STUB_CALLS"
        app="$archive/Products/Applications/$scheme.app"
        binary_dir=$app
        plist_dir=$app
        case "$platform" in
            ios) [[ "$scheme" == "PartyBox Controller" ]]; supported=iPhoneOS ;;
            tvos) [[ "$scheme" == PartyBox ]]; supported=AppleTVOS ;;
            macos)
                [[ "$scheme" == PartyBox ]]
                supported=MacOSX
                plist_dir="$app/Contents"
                binary_dir="$app/Contents/MacOS"
                ;;
        esac
        mkdir -p "$binary_dir"
        printf 'CFBundleVersion=%s\nPartyBoxSentryDSN=%s\nCFBundleSupportedPlatforms.0=%s\nCFBundleExecutable=%s\n' \
            "$build" "$dsn" "$supported" "$scheme" > "$plist_dir/Info.plist"
        printf 'A8230261-A8C4-4484-B75C-7C06E61236D8\n' > "$binary_dir/$scheme"
        dwarf_dir="$archive/dSYMs/$scheme.app.dSYM/Contents/Resources/DWARF"
        if [[ "$platform" != "${STUB_MISSING_SYMBOLS:-}" ]]; then
            mkdir -p "$dwarf_dir"
            cp "$binary_dir/$scheme" "$dwarf_dir/"
            if [[ "$platform" == "${STUB_WRONG_SYMBOLS:-}" ]]; then
                printf '85F1C7F9-D57C-43FF-8CAE-3EA61F4B310F\n' > "$dwarf_dir/$scheme"
            fi
        fi
        ;;
    xcrun)
        [[ -z "${SENTRY_AUTH_TOKEN+x}" ]]
        [[ "$1 $2" == 'dwarfdump --uuid' ]]
        printf 'UUID: %s (arm64) %s\n' "$(cat "$3")" "$3"
        ;;
    plutil)
        [[ -z "${SENTRY_AUTH_TOKEN+x}" ]]
        awk -v key="$2" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); found=1 }
            END { if (!found) exit 1 }' "$6"
        ;;
    sentry-cli)
        [[ "$SENTRY_AUTH_TOKEN" == stub-upload-token ]]
        [[ "$*" == "debug-files upload --wait --org partybox-org --project shared "* ]]
        archive_dir="${8%/app.xcarchive/dSYMs}"
        platform="${archive_dir##*/}"
        printf 'sentry %s\n' "$platform" >> "$STUB_CALLS"
        [[ "$platform" != "${STUB_FAIL_SENTRY:-}" ]]
        ;;
esac
STUB

chmod +x "$tmp_dir/bin/distribution-stub"
for tool in xcodebuild plutil xcrun sentry-cli; do
    ln -s distribution-stub "$tmp_dir/bin/$tool"
done

export PATH="$tmp_dir/bin:$PATH"
export STUB_CALLS="$calls"
export APPLE_TEAM_ID=TEST123456
export SENTRY_DSN=https://public@example.invalid/42
export SENTRY_ORG=partybox-org SENTRY_PROJECT=shared SENTRY_AUTH_TOKEN=stub-upload-token

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    cat "$output" >&2
    exit 1
}

run_ok() {
    : > "$calls"
    "$script" "$@" > "$output" 2>&1 || fail "Expected release command to succeed"
    if grep -q 'stub-upload-token' "$output"; then
        fail "Upload token appeared in output"
    fi
}

run_failure() {
    local expected=$1
    shift
    : > "$calls"
    if "$script" "$@" > "$output" 2>&1; then
        fail "Expected release command to fail"
    fi
    grep -q "$expected" "$output" || fail "Expected error: $expected"
}

expect_calls() {
    local expected
    expected="$(printf '%s\n' "$@")"
    [[ "$(cat "$calls")" == "$expected" ]] || fail "Unexpected calls: $(cat "$calls")"
}

SENTRY_AUTH_TOKEN='' run_failure "SENTRY_AUTH_TOKEN" --build-number 123
expect_calls

STUB_MISSING_SYMBOLS=ios run_failure "missing its app binary or dSYM" --build-number 123
expect_calls "archive ios" "archive tvos" "archive macos"

STUB_WRONG_SYMBOLS=tvos run_failure "UUIDs do not match" --build-number 123
expect_calls "archive ios" "archive tvos" "archive macos"

STUB_FAIL_SENTRY=tvos run_failure "tvos symbol upload failed" --build-number 123
expect_calls "archive ios" "archive tvos" "archive macos" "sentry ios" "sentry tvos"

SENTRY_AUTH_TOKEN='' run_ok --build-number 123 --archive-only
expect_calls "archive ios" "archive tvos" "archive macos"
run_dir="$(sed -n 's/^Release artifacts: //p' "$output")"
[[ -f "$run_dir/archives-ready" ]] || fail "Expected resumable archives"

STUB_FAIL_APPLE=tvos run_failure "tvos Apple upload did not confirm delivery" --resume "$run_dir"
expect_calls "sentry ios" "sentry tvos" "sentry macos" "apple ios" "apple tvos"
[[ -f "$run_dir/ios/apple-uploaded" ]] || fail "Missing iOS receipt"
[[ -f "$run_dir/tvos/apple-upload-started" ]] || fail "Missing unconfirmed tvOS upload state"

run_failure "unconfirmed Apple upload" --resume "$run_dir"
expect_calls
run_ok --resume "$run_dir" --platform tvos --retry-apple-upload
expect_calls "sentry tvos" "apple tvos"
run_ok --resume "$run_dir"
expect_calls "sentry macos" "apple macos"
run_ok --resume "$run_dir"
expect_calls

run_ok --build-number 124 --platform ios
expect_calls "archive ios" "sentry ios" "apple ios"

printf 'Distribution workflow tests passed.\n'
