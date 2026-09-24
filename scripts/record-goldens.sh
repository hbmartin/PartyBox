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
games_backup="$record_root/backup-games"
host_backup="$record_root/backup-host"
mkdir -p "$games_output" "$host_output" "$games_backup" "$host_backup"
rollback_pending=false

copy_json() {
    local source=$1 destination=$2 fixture
    for fixture in "$source"/*.json; do
        cp "$fixture" "$destination/" || return 1
    done
}

restore_fixtures() {
    local fixture
    for fixture in "$games_fixtures"/*.json "$host_fixtures"/*.json; do
        rm -f "$fixture" || return 1
    done
    copy_json "$games_backup" "$games_fixtures" || return 1
    copy_json "$host_backup" "$host_fixtures" || return 1
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "$rollback_pending" == true ]]; then
        echo "Restoring golden fixtures after unsuccessful verification." >&2
        if ! restore_fixtures; then
            echo "Fixture restoration failed; backups retained at $record_root." >&2
            exit 1
        fi
    fi
    rm -rf "$record_root" || status=1
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

install_candidates() {
    local candidates=$1 committed=$2 fixture
    for fixture in "$committed"/*.json; do
        if [[ ! -e "$candidates/$(basename "$fixture")" ]]; then
            rm -f "$fixture"
        fi
    done
    copy_json "$candidates" "$committed"
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
copy_json "$games_fixtures" "$games_backup"
copy_json "$host_fixtures" "$host_backup"
rollback_pending=true
install_candidates "$games_output" "$games_fixtures"
install_candidates "$host_output" "$host_fixtures"

swift test --package-path "$ROOT_DIR/PartyNet" --filter ControllerScreenGoldenTests
xcodebuild -project "$ROOT_DIR/PartyBox.xcodeproj" -scheme PartyBox \
    -testPlan PartyBox-Normal -destination 'platform=macOS' \
    '-only-testing:PartyBoxTests/PartyBoxTests/oversizedNestedControllerLayoutFallsBackToASendableScreen()' \
    test

rollback_pending=false
echo "Golden fixtures recorded and verified. Review the fixture diff before committing."
