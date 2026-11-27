#!/bin/bash
set -euo pipefail
unset CDPATH
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
record_root=""
stage_tag=""
backup_root=""
games_backup=""
host_backup=""
rollback_pending=false
cleanup_phase=recording
signal_status=0
cleanup_cancelled=false

note_signal() {
    if (( signal_status == 0 )); then signal_status=$1; fi
    case "$cleanup_phase" in
        restoring|finalizing) cleanup_cancelled=true ;;
    esac
}

abort_if_signalled() {
    if (( signal_status != 0 )); then exit "$signal_status"; fi
}

sync_can_continue() {
    if [[ "$cleanup_phase" == restoring ]]; then
        [[ "$cleanup_cancelled" == false ]]
    else
        (( signal_status == 0 ))
    fi
}

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
        sync_can_continue || return 1
        if ! staged="$(mktemp "$destination/.partybox-fixture.$stage_tag.XXXXXX")"; then
            status=1
            continue
        fi
        if ! cp -p "$fixture" "$staged"; then
            rm -f "$staged" || true
            status=1
            continue
        fi
        sync_can_continue || return 1
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
        sync_can_continue || return 1
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
    [[ -n "$stage_tag" ]] || return 0
    for staged in "$games_fixtures"/.partybox-fixture."$stage_tag".* \
        "$host_fixtures"/.partybox-fixture."$stage_tag".*; do
        if ! rm -f -- "$staged"; then
            status=1
        fi
    done
    return "$status"
}

write_recovery() {
    # Persist recovery information before attempting to report it on stderr.
    if [[ -d "$backup_root" ]]; then
        printf '%s\n' "$1" 2>/dev/null >>"$backup_root/recovery.log" || true
    fi
    (trap '' INT TERM QUIT; printf '%s\n' "$1" >&2) || true
}

print_recovery() {
    local summary=$1 backup_state=$2 recovery commands
    if [[ "$backup_state" != verified ]]; then
        if [[ "$backup_state" == incomplete ]]; then
            printf -v recovery '%s\nGolden backup missing or incomplete at %s.' "$summary" "$backup_root"
        else
            printf -v recovery '%s\nGolden backup verification was interrupted at %s.' "$summary" "$backup_root"
        fi
        write_recovery "$recovery"$'\n'"Inspect the fixture diff and recover originals from Git or another saved copy."
        return
    fi

    printf -v recovery '%s\nGolden backups retained at %s\n  games: %s\n  host: %s\nInspect the backup contents and fixture diff before restoring.' \
        "$summary" "$backup_root" "$games_backup" "$host_backup"
    write_recovery "$recovery"

    # A cancelled or failed check leaves the operator with only safe guidance.
    if [[ "$cleanup_cancelled" == false ]] && backup_intact && [[ "$cleanup_cancelled" == false ]]; then
        printf -v commands "After resolving the interruption or file error, restore the original fixture sets with:\n  rsync -a --delete --include='*.json' --exclude='*' %q/ %q/\n  rsync -a --delete --include='*.json' --exclude='*' %q/ %q/\n  find %q %q -maxdepth 1 -type f -name %q -delete" \
            "$games_backup" "$games_fixtures" "$host_backup" "$host_fixtures" \
            "$games_fixtures" "$host_fixtures" ".partybox-fixture.$stage_tag.*"
        write_recovery "$commands"
    else
        write_recovery "Backup integrity was not confirmed for manual restoration. Recover originals from Git or another verified copy."
    fi
}

cleanup() {
    local status=$? restore_failed=false
    local backup_state=unchecked stages_failed=false keep_backup=false
    set +e
    trap - EXIT
    if [[ "$rollback_pending" == true ]]; then
        # A terminal hangup must leave both the shell and restore commands running.
        trap '' HUP
        cleanup_phase=restoring
        report "Restoring golden fixtures after unsuccessful verification."
        if [[ "$cleanup_cancelled" == false ]] && backup_intact; then
            backup_state=verified
            if ! sync_json_set "$games_backup" "$games_fixtures" "$games_original_manifest"; then
                restore_failed=true
            fi
            if [[ "$cleanup_cancelled" == true ]] || ! sync_json_set "$host_backup" "$host_fixtures" "$host_original_manifest"; then
                restore_failed=true
            fi
        else
            restore_failed=true
            if [[ "$cleanup_cancelled" == false ]]; then backup_state=incomplete; fi
        fi
        if [[ "$restore_failed" == false ]]; then rollback_pending=false; fi
        if ! cleanup_stages; then stages_failed=true; fi

        if [[ "$rollback_pending" == true ]]; then
            if [[ "$cleanup_cancelled" == true ]]; then
                print_recovery "Fixture restoration interrupted." "$backup_state"
            else
                print_recovery "Automatic fixture restoration was incomplete." "$backup_state"
            fi
            if (( status == 0 )); then status=1; fi
        elif [[ "$stages_failed" == true || "$cleanup_cancelled" == true ]]; then
            keep_backup=true
            write_recovery "Original golden fixtures restored. Staging cleanup failed or was interrupted. Backup retained at $backup_root."
            if (( status == 0 )); then status=1; fi
        fi
    elif ! cleanup_stages; then
        report "Could not remove golden fixture staging files."
        if (( status == 0 )); then status=1; fi
    fi

    cleanup_phase=finalizing
    if [[ -n "$backup_root" && "$rollback_pending" == false && "$keep_backup" == false ]]; then
        if [[ "$cleanup_cancelled" == false ]] && ! rm -rf "$backup_root"; then
            report "Could not remove golden backup at $backup_root"
            if (( status == 0 )); then status=1; fi
        fi
        if [[ "$cleanup_cancelled" == true && -d "$backup_root" ]]; then
            report "Cleanup interrupted. An unused or partially removed golden backup remains at $backup_root."
        fi
    fi
    if [[ -n "$record_root" ]] && ! rm -rf "$record_root"; then
        report "Could not remove temporary golden output at $record_root"
        if (( status == 0 )); then status=1; fi
    fi
    if (( signal_status != 0 )); then status=$signal_status; fi
    exit "$status"
}

# Keep the signal handlers installed across the transition into the EXIT trap.
# They record signals without exiting from inside cleanup.
trap cleanup EXIT
trap 'note_signal 129' HUP
trap 'note_signal 130' INT
trap 'note_signal 131' QUIT
trap 'note_signal 143' TERM

record_root="$(mktemp -d "${TMPDIR:-/tmp}/partybox-goldens.XXXXXX")"
abort_if_signalled
stage_tag="${record_root##*/}"
games_output="$record_root/games"
host_output="$record_root/host"
mkdir -p "$games_output" "$host_output"
abort_if_signalled

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

abort_if_signalled
env TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR="$host_output" \
    xcodebuild -project "$ROOT_DIR/PartyBox.xcodeproj" -scheme PartyBox \
    -testPlan PartyBox-Normal -destination 'platform=macOS' \
    '-only-testing:PartyBoxTests/PartyBoxTests/oversizedNestedControllerLayoutFallsBackToASendableScreen()' \
    ENABLE_APP_SANDBOX=NO test >"$record_root/host.log" 2>&1 || {
        tail -80 "$record_root/host.log" >&2
        exit 1
    }

abort_if_signalled
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
report "Temporary rollback backup: $backup_root"
abort_if_signalled
rollback_pending=true
sync_json_set "$games_output" "$games_fixtures" "$games_candidate_manifest"
abort_if_signalled
sync_json_set "$host_output" "$host_fixtures" "$host_candidate_manifest"
abort_if_signalled

swift test --package-path "$ROOT_DIR/PartyNet" --filter ControllerScreenGoldenTests
abort_if_signalled
xcodebuild -project "$ROOT_DIR/PartyBox.xcodeproj" -scheme PartyBox \
    -testPlan PartyBox-Normal -destination 'platform=macOS' \
    '-only-testing:PartyBoxTests/PartyBoxTests/oversizedNestedControllerLayoutFallsBackToASendableScreen()' \
    test

abort_if_signalled
rollback_pending=false
(printf '%s\n' "Golden fixtures recorded and verified. Review the fixture diff before committing.") || true
