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
cleanup_log="$record_root/cleanup.log"
stage_tag="${record_root##*/}"
games_output="$record_root/games"
host_output="$record_root/host"
backup_root=""
games_backup=""
host_backup=""
games_original_manifest="$record_root/games-original.manifest"
host_original_manifest="$record_root/host-original.manifest"
games_candidate_manifest="$record_root/games-candidate.manifest"
host_candidate_manifest="$record_root/host-candidate.manifest"
mkdir -p "$games_output" "$host_output"
: >"$cleanup_log"
rollback_pending=false

fixture_manifest() {
    local directory=$1 fixture
    [[ -d "$directory" ]] || return 1
    for fixture in "$directory"/*.json; do
        printf '%s ' "${fixture##*/}"
        cksum <"$fixture" || return 1
    done
}

backup_intact() {
    [[ -f "$games_original_manifest" && -f "$host_original_manifest" ]] || return 1
    fixture_manifest "$games_backup" >"$record_root/games-current.manifest" || return 1
    fixture_manifest "$host_backup" >"$record_root/host-current.manifest" || return 1
    cmp -s "$games_original_manifest" "$record_root/games-current.manifest" \
        && cmp -s "$host_original_manifest" "$record_root/host-current.manifest"
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
    fixture_manifest "$source" >"$record_root/source-current.manifest" || return 1
    cmp -s "$expected_manifest" "$record_root/source-current.manifest" || return 1
    source_fixtures=("$source"/*.json)
    for fixture in "${source_fixtures[@]}"; do
        if ! mktemp "$destination/.partybox-fixture.$stage_tag.XXXXXX" >"$record_root/staged-path"; then
            status=1
            continue
        fi
        if ! read -r staged <"$record_root/staged-path"; then
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
    [[ -d "$source" ]] || return 1
    fixture_manifest "$source" >"$record_root/source-current.manifest" || return 1
    cmp -s "$expected_manifest" "$record_root/source-current.manifest" || return 1
    for fixture in "$destination"/*.json; do
        found=false
        for source_fixture in "${source_fixtures[@]}"; do
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
    if ! backup_intact; then
        echo "Golden backup missing or incomplete at $backup_root; automatic restoration was not completed." >>"$cleanup_log"
        echo "Inspect the fixture diff and recover originals from Git or another saved copy." >>"$cleanup_log"
        return 1
    fi
    {
        echo "Golden backups retained at $backup_root"
        echo "  games: $games_backup"
        echo "  host: $host_backup"
        echo "After resolving the interruption or file error, restore the original fixture sets with:"
        printf "  rsync -a --delete --include='*.json' --exclude='*' %q/ %q/\n" "$games_backup" "$games_fixtures"
        printf "  rsync -a --delete --include='*.json' --exclude='*' %q/ %q/\n" "$host_backup" "$host_fixtures"
        printf '  rm -f -- %q/.partybox-fixture.%s.* %q/.partybox-fixture.%s.*\n' \
            "$games_fixtures" "$stage_tag" "$host_fixtures" "$stage_tag"
    } >>"$cleanup_log"
}

flush_cleanup_log() {
    cat "$cleanup_log" >&2 || true
}

retain_cleanup_log() {
    if [[ "$rollback_pending" == true && -d "$backup_root" ]]; then
        cat "$cleanup_log" >"$backup_root/recovery.log" || true
    fi
}

cleanup_interrupted() {
    local status=$1
    set +e
    trap - EXIT INT TERM
    if ! cleanup_stages; then
        echo "Could not remove golden fixture staging files." >>"$cleanup_log"
    fi
    if [[ "$rollback_pending" == true ]]; then
        echo "Fixture restoration interrupted." >>"$cleanup_log"
        print_recovery
    fi
    retain_cleanup_log
    flush_cleanup_log
    rm -rf "$record_root"
    exit "$status"
}

cleanup() {
    local status=$? restore_failed=false
    set +e
    trap 'cleanup_interrupted 130' INT
    trap 'cleanup_interrupted 143' TERM
    trap - EXIT
    if [[ "$rollback_pending" == true ]]; then
        echo "Restoring golden fixtures after unsuccessful verification." >>"$cleanup_log"
        echo "Recovery backup: $backup_root" >>"$cleanup_log"
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
            print_recovery
            if (( status == 0 )); then status=1; fi
        else
            rollback_pending=false
        fi
    elif ! cleanup_stages; then
        echo "Could not remove golden fixture staging files." >>"$cleanup_log"
        if (( status == 0 )); then status=1; fi
    fi
    if [[ -n "$backup_root" && "$rollback_pending" == false ]]; then
        if ! rm -rf "$backup_root"; then
            echo "Could not remove golden backup at $backup_root" >>"$cleanup_log"
            if (( status == 0 )); then status=1; fi
        fi
    fi
    retain_cleanup_log
    flush_cleanup_log
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
fixture_manifest "$games_output" >"$games_candidate_manifest"
fixture_manifest "$host_output" >"$host_candidate_manifest"
fixture_manifest "$games_fixtures" >"$games_original_manifest"
fixture_manifest "$host_fixtures" >"$host_original_manifest"
mkdir -p "$ROOT_DIR/.verification/golden-backups"
backup_root="$(mktemp -d "$ROOT_DIR/.verification/golden-backups/partybox-goldens.XXXXXX")"
games_backup="$backup_root/backup-games"
host_backup="$backup_root/backup-host"
mkdir -p "$games_backup" "$host_backup"
copy_json "$games_fixtures" "$games_backup"
copy_json "$host_fixtures" "$host_backup"
backup_intact
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
