#!/bin/bash
set -euo pipefail
shopt -s nullglob

allow_set_change=false
case "${1:-}" in
    "") ;;
    --allow-set-change) allow_set_change=true ;;
    *) echo "usage: scripts/record-goldens.sh [--allow-set-change]" >&2; exit 2 ;;
esac
if (( $# > 1 )); then
    echo "usage: scripts/record-goldens.sh [--allow-set-change]" >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
games_fixtures="$ROOT_DIR/PartyNet/Tests/PartyGamesTests/Fixtures"
host_fixtures="$ROOT_DIR/PartyBoxTests/Fixtures"
record_root="$(mktemp -d "${TMPDIR:-/tmp}/partybox-goldens.XXXXXX")"
stage_tag="${record_root##*/}"
games_output="$record_root/games"
host_output="$record_root/host"
backup_root=""
games_backup=""
host_backup=""
mkdir -p "$games_output" "$host_output"
rollback_pending=false

report() {
    # A broken stderr pipe must only terminate the reporting subprocess.
    (printf '%s\n' "$1" >&2) || true
}

fixture_manifest() {
    local directory=$1 fixture
    [[ -d "$directory" ]] || return 1
    for fixture in "$directory"/*.json; do
        printf '%s ' "${fixture##*/}"
        cksum <"$fixture" || return 1
    done
}

matches_manifest() {
    local actual
    actual="$(fixture_manifest "$1")" && [[ "$actual" == "$2" ]]
}

backup_intact() {
    matches_manifest "$games_backup" "$games_original_manifest" \
        && matches_manifest "$host_backup" "$host_original_manifest"
}

copy_json() {
    local source=$1 destination=$2 fixture
    for fixture in "$source"/*.json; do
        cp -p "$fixture" "$destination/" || return 1
    done
}

sync_json_set() {
    local source=$1 destination=$2 expected_manifest=$3 fixture source_fixture staged found status=0
    local -a source_fixtures
    [[ -d "$source" && -d "$destination" ]] || return 1
    matches_manifest "$source" "$expected_manifest" || return 1
    source_fixtures=("$source"/*.json)
    # Bash 3.2 treats empty arrays as unset under nounset.
    for fixture in ${source_fixtures[@]+"${source_fixtures[@]}"}; do
        if ! staged="$(mktemp "$destination/.partybox-fixture.$stage_tag.XXXXXX")"; then
            status=1
            continue
        fi
        if ! cp -p "$fixture" "$staged"; then
            rm -f "$staged" || true
            status=1
            continue
        fi
        if ! mv -f "$staged" "$destination/${fixture##*/}"; then
            rm -f "$staged" || true
            status=1
        fi
    done

    if (( status != 0 )); then
        return 1
    fi
    matches_manifest "$source" "$expected_manifest" || return 1
    for fixture in "$destination"/*.json; do
        found=false
        for source_fixture in ${source_fixtures[@]+"${source_fixtures[@]}"}; do
            if [[ "${source_fixture##*/}" == "${fixture##*/}" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            if ! rm -f "$fixture"; then
                status=1
            fi
        fi
    done
    return "$status"
}

cleanup_stages() {
    local staged status=0
    for staged in "$games_fixtures"/.partybox-fixture."$stage_tag".* \
        "$host_fixtures"/.partybox-fixture."$stage_tag".*; do
        if ! rm -f -- "$staged"; then
            status=1
        fi
    done
    return "$status"
}

print_recovery() {
    local recovery
    recovery="$(
        printf '%s\n' "$1"
        if backup_intact; then
            echo "Golden backups retained at $backup_root"
            echo "  games: $games_backup"
            echo "  host: $host_backup"
            echo "After resolving the interruption or file error, restore the original fixture sets with:"
            printf "  rsync -a --delete --include='*.json' --exclude='*' %q/ %q/\n" "$games_backup" "$games_fixtures"
            printf "  rsync -a --delete --include='*.json' --exclude='*' %q/ %q/\n" "$host_backup" "$host_fixtures"
            printf '  find %q %q -maxdepth 1 -type f -name %q -delete\n' \
                "$games_fixtures" "$host_fixtures" ".partybox-fixture.$stage_tag.*"
        else
            echo "Golden backup missing or incomplete at $backup_root."
            echo "Inspect the fixture diff and recover originals from Git or another saved copy."
        fi
    )"
    report "$recovery"
    if [[ -d "$backup_root" ]]; then
        printf '%s\n' "$recovery" >"$backup_root/recovery.log" || true
    fi
}

cleanup_interrupted() {
    local status=$1
    set +e
    trap - EXIT
    trap '' HUP INT QUIT TERM
    if ! cleanup_stages; then
        report "Could not remove golden fixture staging files."
    fi
    if [[ "$rollback_pending" == true ]]; then
        print_recovery "Fixture restoration interrupted."
    elif [[ -d "$backup_root" ]]; then
        report "Cleanup interrupted. An unused or partially removed golden backup remains at $backup_root."
    fi
    rm -rf "$record_root" || report "Could not remove temporary golden output at $record_root"
    exit "$status"
}

cleanup() {
    local status=$? restore_failed=false
    set +e
    trap 'cleanup_interrupted 129' HUP
    trap 'cleanup_interrupted 130' INT
    trap 'cleanup_interrupted 131' QUIT
    trap 'cleanup_interrupted 143' TERM
    trap - EXIT
    if [[ "$rollback_pending" == true ]]; then
        report "Restoring golden fixtures after unsuccessful verification."
        if ! backup_intact; then
            restore_failed=true
        else
            if ! sync_json_set "$games_backup" "$games_fixtures" "$games_original_manifest"; then
                restore_failed=true
            fi
            if ! sync_json_set "$host_backup" "$host_fixtures" "$host_original_manifest"; then
                restore_failed=true
            fi
        fi
        if ! cleanup_stages; then restore_failed=true; fi
        if [[ "$restore_failed" == true ]]; then
            print_recovery "Automatic fixture restoration was incomplete."
            if (( status == 0 )); then status=1; fi
        else
            rollback_pending=false
        fi
    elif ! cleanup_stages; then
        report "Could not remove golden fixture staging files."
        if (( status == 0 )); then status=1; fi
    fi
    if [[ -n "$backup_root" && "$rollback_pending" == false ]]; then
        if ! rm -rf "$backup_root"; then
            report "Could not remove golden backup at $backup_root"
            if (( status == 0 )); then status=1; fi
        fi
    fi
    if ! rm -rf "$record_root"; then
        report "Could not remove temporary golden output at $record_root"
        if (( status == 0 )); then status=1; fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM

fixture_names() {
    local directory=$1 fixture
    for fixture in "$directory"/*.json; do
        basename "$fixture"
    done | sort
}

check_candidate_set() {
    local label=$1 candidates=$2 committed=$3
    if [[ -z "$(fixture_names "$candidates")" ]]; then
        echo "$label recording produced no JSON candidates." >&2
        exit 1
    fi
    if ! diff -u <(fixture_names "$committed") <(fixture_names "$candidates"); then
        if [[ "$allow_set_change" != true ]]; then
            echo "$label candidate filenames differ from committed fixtures; rerun with --allow-set-change to accept additions or removals." >&2
            exit 1
        fi
    fi
}

env PARTYBOX_GOLDEN_OUTPUT_DIR="$games_output" \
    swift test --package-path "$ROOT_DIR/PartyNet" --filter ControllerScreenGoldenTests \
    >"$record_root/games.log" 2>&1 || {
        tail -80 "$record_root/games.log" >&2
        exit 1
    }

env TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR="$host_output" \
    xcodebuild -project "$ROOT_DIR/PartyBox.xcodeproj" -scheme PartyBox \
    -testPlan PartyBox-Normal -destination 'platform=macOS' \
    '-only-testing:PartyBoxTests/PartyBoxTests/oversizedNestedControllerLayoutFallsBackToASendableScreen()' \
    ENABLE_APP_SANDBOX=NO test >"$record_root/host.log" 2>&1 || {
        tail -80 "$record_root/host.log" >&2
        exit 1
    }

check_candidate_set PartyGames "$games_output" "$games_fixtures"
check_candidate_set PartyBox "$host_output" "$host_fixtures"
games_candidate_manifest="$(fixture_manifest "$games_output")"
host_candidate_manifest="$(fixture_manifest "$host_output")"
games_original_manifest="$(fixture_manifest "$games_fixtures")"
host_original_manifest="$(fixture_manifest "$host_fixtures")"
mkdir -p "$ROOT_DIR/.verification/golden-backups"
backup_root="$(mktemp -d "$ROOT_DIR/.verification/golden-backups/partybox-goldens.XXXXXX")"
games_backup="$backup_root/backup-games"
host_backup="$backup_root/backup-host"
mkdir -p "$games_backup" "$host_backup"
copy_json "$games_fixtures" "$games_backup"
copy_json "$host_fixtures" "$host_backup"
if ! backup_intact; then
    report "Golden backup verification failed at $backup_root."
    exit 1
fi
report "Recovery backup: $backup_root"
rollback_pending=true
sync_json_set "$games_output" "$games_fixtures" "$games_candidate_manifest"
sync_json_set "$host_output" "$host_fixtures" "$host_candidate_manifest"

swift test --package-path "$ROOT_DIR/PartyNet" --filter ControllerScreenGoldenTests
xcodebuild -project "$ROOT_DIR/PartyBox.xcodeproj" -scheme PartyBox \
    -testPlan PartyBox-Normal -destination 'platform=macOS' \
    '-only-testing:PartyBoxTests/PartyBoxTests/oversizedNestedControllerLayoutFallsBackToASendableScreen()' \
    test

rollback_pending=false
echo "Golden fixtures recorded and verified. Review the fixture diff before committing."
