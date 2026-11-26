#!/bin/bash
set -euo pipefail
unset CDPATH

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
        [[ "$(umask)" == 0022 ]]
        archive=""
        export_plist=""
        exporting=false
        scheme=""
        build=""
        dsn=""
        sentry_environment=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -exportArchive) exporting=true ;;
                -archivePath) archive=$2; shift ;;
                -exportOptionsPlist) export_plist=$2; shift ;;
                -scheme) scheme=$2; shift ;;
                CURRENT_PROJECT_VERSION=*) build="${1#*=}" ;;
                PARTYBOX_SENTRY_DSN=*) dsn="${1#*=}" ;;
                PARTYBOX_SENTRY_ENVIRONMENT=*) sentry_environment="${1#*=}" ;;
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
            if [[ -n "${STUB_APPLE_HOLD_DIR:-}" ]]; then
                touch "$STUB_APPLE_HOLD_DIR/ready"
                while [[ -d "$STUB_APPLE_HOLD_DIR" && ! -e "$STUB_APPLE_HOLD_DIR/release" ]]; do
                    sleep 0.05
                done
                exit 1
            fi
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
        if [[ "${STUB_OMIT_SENTRY_ENVIRONMENT:-}" != true ]]; then
            printf 'PartyBoxSentryEnvironment=%s\n' "${STUB_SENTRY_ENVIRONMENT:-$sentry_environment}" >> "$plist_dir/Info.plist"
        fi
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

STUB_OMIT_SENTRY_ENVIRONMENT=true run_failure "missing its Sentry environment" --build-number 123 --platform ios
expect_calls "archive ios"
STUB_SENTRY_ENVIRONMENT=local run_failure "wrong Sentry environment" --build-number 123 --platform ios
expect_calls "archive ios"

STUB_FAIL_SENTRY=tvos run_failure "tvos symbol upload failed" --build-number 123
expect_calls "archive ios" "archive tvos" "archive macos" "sentry ios" "sentry tvos"

SENTRY_AUTH_TOKEN='' run_ok --build-number 123 --archive-only
expect_calls "archive ios" "archive tvos" "archive macos"
run_dir="$(sed -n 's/^Release artifacts: //p' "$output")"
[[ -f "$run_dir/archives-ready" ]] || fail "Expected resumable archives"
[[ -n "$(find "$run_dir" -prune -perm 0700 -print)" ]] || fail "Expected a private release directory"
[[ -n "$(find "$run_dir/ios" -prune -perm 0700 -print)" ]] || fail "Expected private platform directories"
[[ -n "$(find "$run_dir/ios/archive.log" -perm 0600 -print)" ]] || fail "Expected private archive logs"

ios_plist="$run_dir/ios/app.xcarchive/Products/Applications/PartyBox Controller.app/Info.plist"
awk '{ sub(/^PartyBoxSentryEnvironment=testflight$/, "PartyBoxSentryEnvironment=local"); print }' \
    "$ios_plist" > "$tmp_dir/local-info"
mv "$tmp_dir/local-info" "$ios_plist"
run_failure "ios archive has the wrong Sentry environment" --resume "$run_dir"
expect_calls
grep -v '^PartyBoxSentryEnvironment=' "$ios_plist" > "$tmp_dir/legacy-info"
mv "$tmp_dir/legacy-info" "$ios_plist"

mac_app="$run_dir/macos/app.xcarchive/Products/Applications/PartyBox.app"
mac_plist="$mac_app/Contents/Info.plist"
grep -v '^PartyBoxSentryEnvironment=' "$mac_plist" > "$tmp_dir/legacy-mac-info"
mv "$tmp_dir/legacy-mac-info" "$mac_plist"
mkdir "$mac_app/Contents/_CodeSignature"
signature="$mac_app/Contents/_CodeSignature/CodeResources"
printf 'stub signature\n' > "$signature"
chmod 600 "$signature"
run_failure "First affected path: .*CodeResources" --resume "$run_dir"
expect_calls
chmod 644 "$signature"
chmod 700 "$mac_app/Contents/_CodeSignature"
run_failure "First affected path: .*_CodeSignature" --resume "$run_dir"
expect_calls
chmod 755 "$mac_app/Contents/_CodeSignature"

(
    cd "$checkout"
    CDPATH=. STUB_FAIL_APPLE=tvos run_failure "tvos Apple upload did not confirm delivery" \
        --resume ".distribution/${run_dir##*/}"
)
expect_calls "sentry ios" "sentry tvos" "sentry macos" "apple ios" "apple tvos"
grep -F 'warning: ios legacy archive is missing its Sentry environment.' "$output" >/dev/null \
    || fail "Expected an iOS legacy archive warning"
[[ -n "$(find "$run_dir/ExportOptions.plist" -perm 0600 -print)" ]] || fail "Expected private export options"
[[ -f "$run_dir/ios/apple-uploaded" ]] || fail "Missing iOS receipt"
[[ -f "$run_dir/tvos/apple-upload-started" ]] || fail "Missing unconfirmed tvOS upload state"

[[ -f "$run_dir/.lock" ]] || fail "Expected a persistent lock file"
# Re-create the pre-upgrade directory format after the previous holder has exited.
rm "$run_dir/.lock"
mkdir "$run_dir/.lock"
run_failure "stale lock recovery" --resume "$run_dir"
expect_calls
rmdir "$run_dir/.lock"
[[ -f "$run_dir/ios/apple-uploaded" && -f "$run_dir/tvos/apple-upload-started" ]] || fail "Lock recovery lost upload state"

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

# A surviving Apple worker must keep the release locked after the script is killed.
SENTRY_AUTH_TOKEN='' run_ok --build-number 125 --platform macos --archive-only
held_run="$(sed -n 's/^Release artifacts: //p' "$output")"
hold_dir="$tmp_dir/hold"
mkdir "$hold_dir"
STUB_APPLE_HOLD_DIR="$hold_dir" "$script" --resume "$held_run" > "$tmp_dir/holder.log" 2>&1 &
holder=$!
cleanup_holder() {
    touch "$hold_dir/release"
    if [[ -n "$holder" ]]; then
        kill -TERM "$holder" 2>/dev/null || true
        wait "$holder" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup_holder EXIT

for _ in $(seq 1 200); do
    [[ -e "$hold_dir/ready" ]] && break
    sleep 0.05
done
[[ -e "$hold_dir/ready" ]] || fail "Apple worker did not start"
run_failure "Release directory is in use" --resume "$held_run"
expect_calls
kill -KILL "$holder"
wait "$holder" 2>/dev/null || true
holder=""
run_failure "Release directory is in use" --resume "$held_run"
expect_calls
touch "$hold_dir/release"
for _ in $(seq 1 200); do
    if "$script" --resume "$held_run" > "$output" 2>&1; then
        fail "Expected an unconfirmed Apple upload"
    fi
    if grep -q 'unconfirmed Apple upload' "$output"; then break; fi
    grep -q 'Release directory is in use' "$output" || fail "Unexpected lock recovery error"
    sleep 0.05
done
grep -q 'unconfirmed Apple upload' "$output" || fail "Lock was not released after Apple worker exited"
trap 'rm -rf "$tmp_dir"' EXIT
run_ok --resume "$held_run" --platform macos --retry-apple-upload
expect_calls "sentry macos" "apple macos"

printf 'Distribution workflow tests passed.\n'
