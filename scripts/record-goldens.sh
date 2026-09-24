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
games_output="$record_root/games"
host_output="$record_root/host"
backup_root=""
games_backup=""
host_backup=""
mkdir -p "$games_output" "$host_output"
rollback_pending=false

copy_json() {
    local source=$1 destination=$2 fixture
    for fixture in "$source"/*.json; do
        cp -p "$fixture" "$destination/" || return 1
    done
}

sync_json_set() {
    local source=$1 destination=$2 fixture staged status=0
    for fixture in "$source"/*.json; do
        if ! staged="$(mktemp "$destination/.partybox-fixture.XXXXXX")"; then
            status=1
            continue
        fi
        if ! cp -p "$fixture" "$staged"; then
            rm -f "$staged" || true
            status=1
            continue
        fi
        if ! mv -f "$staged" "$destination/$(basename "$fixture")"; then
            rm -f "$staged" || true
            status=1
        fi
    done

    if (( status != 0 )); then
        return 1
    fi
    for fixture in "$destination"/*.json; do
        if [[ ! -e "$source/$(basename "$fixture")" ]]; then
            if ! rm -f "$fixture"; then
                status=1
            fi
        fi
    done
    return "$status"
}

print_recovery() {
    echo "Golden backups retained at $backup_root" >&2
    echo "  games: $games_backup" >&2
    echo "  host: $host_backup" >&2
    echo "After fixing the copy error, restore the original fixture sets with:" >&2
    printf "  rsync -a --delete --include='*.json' --exclude='*' %q/ %q/\n" "$games_backup" "$games_fixtures" >&2
    printf "  rsync -a --delete --include='*.json' --exclude='*' %q/ %q/\n" "$host_backup" "$host_fixtures" >&2
}

cleanup_interrupted() {
    local status=$1
    trap - EXIT INT TERM
    if [[ "$rollback_pending" == true ]]; then
        echo "Fixture restoration interrupted." >&2
        print_recovery
    fi
    exit "$status"
}

cleanup() {
    local status=$? restore_failed=false
    trap 'cleanup_interrupted 130' INT
    trap 'cleanup_interrupted 143' TERM
    trap - EXIT
    if [[ "$rollback_pending" == true ]]; then
        echo "Restoring golden fixtures after unsuccessful verification." >&2
        echo "Recovery backup: $backup_root" >&2
        if ! sync_json_set "$games_backup" "$games_fixtures"; then
            restore_failed=true
        fi
        if ! sync_json_set "$host_backup" "$host_fixtures"; then
            restore_failed=true
        fi
        if [[ "$restore_failed" == true ]]; then
            print_recovery
            if (( status == 0 )); then status=1; fi
        else
            rollback_pending=false
        fi
    fi
    if [[ -n "$backup_root" && "$rollback_pending" == false ]]; then
        if ! rm -rf "$backup_root"; then
            echo "Could not remove golden backup at $backup_root" >&2
            if (( status == 0 )); then status=1; fi
        fi
    fi
    if ! rm -rf "$record_root"; then
        echo "Could not remove temporary golden output at $record_root" >&2
        if (( status == 0 )); then status=1; fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
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
mkdir -p "$ROOT_DIR/.verification/golden-backups"
backup_root="$(mktemp -d "$ROOT_DIR/.verification/golden-backups/partybox-goldens.XXXXXX")"
games_backup="$backup_root/backup-games"
host_backup="$backup_root/backup-host"
mkdir -p "$games_backup" "$host_backup"
copy_json "$games_fixtures" "$games_backup"
copy_json "$host_fixtures" "$host_backup"
rollback_pending=true
sync_json_set "$games_output" "$games_fixtures"
sync_json_set "$host_output" "$host_fixtures"

swift test --package-path "$ROOT_DIR/PartyNet" --filter ControllerScreenGoldenTests
xcodebuild -project "$ROOT_DIR/PartyBox.xcodeproj" -scheme PartyBox \
    -testPlan PartyBox-Normal -destination 'platform=macOS' \
    '-only-testing:PartyBoxTests/PartyBoxTests/oversizedNestedControllerLayoutFallsBackToASendableScreen()' \
    test

rollback_pending=false
echo "Golden fixtures recorded and verified. Review the fixture diff before committing."
