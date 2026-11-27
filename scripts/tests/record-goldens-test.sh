#!/bin/bash
set -euo pipefail
unset CDPATH
shopt -s nullglob

source_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/record-goldens.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/partybox-record-test.XXXXXX")"
test_root="$(cd "$test_root" && pwd -P)"
real_cp="$(command -v cp)"
real_rm="$(command -v rm)"
real_mkdir="$(command -v mkdir)"
real_cksum="$(command -v cksum)"
cleanup_test_root() {
    local status=$?
    trap - EXIT
    if (( status == 0 )); then
        "$real_rm" -rf "$test_root"
    else
        echo "Test artifacts retained at $test_root" >&2
    fi
}
trap cleanup_test_root EXIT

fail() { echo "$*" >&2; exit 1; }

make_case() {
    local root="$test_root/$1"
    mkdir -p "$root/scripts" "$root/bin" "$root/tmp" \
        "$root/PartyNet/Tests/PartyGamesTests/Fixtures" "$root/PartyBoxTests/Fixtures"
    git -C "$root" init --quiet --template=
    if [[ "$1" == double_signal_cleanup_entry || "$1" == before_backup_check_signal ]]; then
        awk -v scenario="$1" '{ print }
             (scenario == "double_signal_cleanup_entry" && /^    local status=.*restore_failed=false$/) ||
             (scenario == "before_backup_check_signal" && /^        report "Restoring golden fixtures/) {
                 print "    kill -TERM \"$$\""; injected=1
             }
             END { if (!injected) exit 1 }' \
            "$source_script" >"$root/scripts/record-goldens.sh"
    else
        "$real_cp" "$source_script" "$root/scripts/record-goldens.sh"
    fi
    printf '{"original":"games"}\n' >"$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json"
    printf '{"original":"host"}\n' >"$root/PartyBoxTests/Fixtures/unavailable-screen.json"

    cat >"$root/bin/swift" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "$STUB_SCENARIO" == lock_checks ]]; then probe-lock "swift${PARTYBOX_GOLDEN_OUTPUT_DIR:+-record}"; fi
if [[ "$STUB_SCENARIO" == lock_contender ]]; then touch "$TMPDIR/contender-started"; fi
if [[ -n "${PARTYBOX_GOLDEN_OUTPUT_DIR:-}" ]]; then
    if [[ "$STUB_SCENARIO" == empty_output ]]; then
        exit 0
    elif [[ "$STUB_SCENARIO" == set_change || "$STUB_SCENARIO" == backup_disappears \
        || "$STUB_SCENARIO" == backup_incomplete ]]; then
        printf '{"candidate":"new-game"}\n' >"$PARTYBOX_GOLDEN_OUTPUT_DIR/new-game.json"
    else
        printf '{"candidate":"game"}\n' >"$PARTYBOX_GOLDEN_OUTPUT_DIR/game.json"
    fi
    if [[ "$STUB_SCENARIO" == recording_fail ]]; then exit 1; fi
else
    if [[ "$STUB_SCENARIO" == crash_after_install ]]; then
        kill -KILL "$PPID"
        exit 0
    elif [[ "$STUB_SCENARIO" == clean_while_locked ]]; then
        case_root="$(cd "$(dirname "$0")/.." && pwd)"
        git -C "$case_root" clean -fdx
        [[ ! -e "$case_root/.verification" ]]
        probe-lock after-clean
        exit 76
    elif [[ "$STUB_SCENARIO" == linked_worktree ]]; then
        other="$LINKED_TEST_WORKTREE"
        PATH="$other/bin:$PATH" TMPDIR="$other/tmp" STUB_SCENARIO=normal \
            /bin/bash "$other/scripts/record-goldens.sh" >"$other/run.log" 2>&1
        exit 76
    elif [[ "$STUB_SCENARIO" == late_restore_signal || "$STUB_SCENARIO" == incomplete_backup_signal \
        || "$STUB_SCENARIO" == staging_delete_fail ]]; then
        case_root="$(cd "$(dirname "$0")/.." && pwd)"
        for scratch in "$TMPDIR"/partybox-goldens.*; do
            touch "$case_root/PartyNet/Tests/PartyGamesTests/Fixtures/.partybox-fixture.${scratch##*/}.probe"
            if [[ "$STUB_SCENARIO" == staging_delete_fail ]]; then
                touch "$case_root/PartyBoxTests/Fixtures/.partybox-fixture.${scratch##*/}.probe"
            fi
        done
        if [[ "$STUB_SCENARIO" == incomplete_backup_signal ]]; then
            "$REAL_RM" "$case_root"/.git/partybox-goldens/golden-backups/partybox-goldens.*/backup-games/game.json
        fi
        exit 1
    elif [[ "$STUB_SCENARIO" == recovery_checksum_signal ]]; then
        printf '%s\n' "$PPID" >"$TMPDIR/recorder-pid"
        exit 1
    elif [[ "$STUB_SCENARIO" == interrupt_int ]]; then
        kill -INT "$PPID"
        exit 0
    elif [[ "$STUB_SCENARIO" == interrupt_term || "$STUB_SCENARIO" == cleanup_term \
        || "$STUB_SCENARIO" == double_signal_cleanup_entry ]]; then
        kill -TERM "$PPID"
        exit 0
    elif [[ "$STUB_SCENARIO" == interrupt_quit ]]; then
        kill -QUIT "$PPID"
        exit 0
    elif [[ "$STUB_SCENARIO" == interrupt_hup ]]; then
        kill -HUP "$PPID"
        exit 0
    elif [[ "$STUB_SCENARIO" == scratch_lost ]]; then
        "$REAL_RM" -rf "$TMPDIR"/partybox-goldens.*
        exit 1
    elif [[ "$STUB_SCENARIO" == broken_stdout || "$STUB_SCENARIO" == verify_fail ]]; then
        printf 'Swift verification stdout\n'
        if [[ "$STUB_SCENARIO" == verify_fail ]]; then exit 76; fi
    elif [[ "$STUB_SCENARIO" == before_backup_check_signal || "$STUB_SCENARIO" == games_restore_copy_fail \
        || "$STUB_SCENARIO" == host_restore_copy_fail || "$STUB_SCENARIO" == closed_stderr \
        || "$STUB_SCENARIO" == broken_stderr || "$STUB_SCENARIO" == broken_stderr_log_unwritable \
        || "$STUB_SCENARIO" == append_recovery || "$STUB_SCENARIO" == restore_hup \
        || "$STUB_SCENARIO" == stage_restore_interrupt || "$STUB_SCENARIO" == empty_backup \
        || "$STUB_SCENARIO" == cleanup_int || "$STUB_SCENARIO" == cleanup_removal_int ]]; then
        exit 1
    elif [[ "$STUB_SCENARIO" == backup_disappears || "$STUB_SCENARIO" == backup_incomplete ]]; then
        case_root="$(cd "$(dirname "$0")/.." && pwd)"
        if [[ "$STUB_SCENARIO" == backup_disappears ]]; then
            mv "$case_root/.git/partybox-goldens/golden-backups" "$case_root/moved-backup"
        else
            for fixture in "$case_root"/.git/partybox-goldens/golden-backups/partybox-goldens.*/backup-games/game.json; do
                "$REAL_RM" "$fixture"
            done
        fi
        exit 1
    fi
fi
SH
    cat >"$root/bin/xcodebuild" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "$STUB_SCENARIO" == lock_checks ]]; then probe-lock "xcode${TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR:+-record}"; fi
if [[ "$STUB_SCENARIO" == lock_contender ]]; then touch "$TMPDIR/contender-started"; fi
if [[ -n "${TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR:-}" ]]; then
    if [[ "$STUB_SCENARIO" == host_restore_rm_fail ]]; then
        printf '{"candidate":"new-host"}\n' >"$TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR/new-host.json"
    else
        printf '{"candidate":"host"}\n' >"$TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR/unavailable-screen.json"
    fi
elif [[ "$STUB_SCENARIO" == broken_stdout || "$STUB_SCENARIO" == host_verify_fail ]]; then
    printf 'Xcode verification stdout\n'
    if [[ "$STUB_SCENARIO" == host_verify_fail ]]; then exit 77; fi
elif [[ "$STUB_SCENARIO" == lock_checks || "$STUB_SCENARIO" == host_restore_rm_fail ]]; then
    exit 1
fi
SH
    cat >"$root/bin/probe-lock" <<'SH'
#!/bin/bash
set -euo pipefail
case_root="$(cd "$(dirname "$0")/.." && pwd)"
# Swift and Xcode can launch helpers that survive the recorder.
if [[ "$1" != rollback && -e /dev/fd/9 ]]; then exit 81; fi
status=0
STUB_SCENARIO=lock_contender /bin/bash "$case_root/scripts/record-goldens.sh" >"$TMPDIR/contender.log" 2>&1 &
contender=$!
for ((poll=0; poll<100; poll++)); do
    kill -0 "$contender" 2>/dev/null || break
    sleep 0.05
done
if kill -0 "$contender" 2>/dev/null; then
    kill -KILL "$contender" 2>/dev/null || true
    wait "$contender" || true
    exit 82
fi
wait "$contender" || status=$?
[[ "$status" == 75 && ! -e "$TMPDIR/contender-started" ]]
grep -Fq 'Another golden fixture recording is in progress' "$TMPDIR/contender.log"
echo "$1" >>"$TMPDIR/lock-checks"
SH
    cat >"$root/bin/cp" <<'SH'
#!/bin/bash
set -euo pipefail
shopt -s nullglob
source_file=$2
case "$STUB_SCENARIO:$source_file" in
    lock_checks:*/backup-host/*.json) probe-lock rollback ;;
    games_install_copy_fail:*/games/*.json|host_install_copy_fail:*/host/*.json)
        exit 74 ;;
    games_restore_copy_fail:*/backup-games/*.json|host_restore_copy_fail:*/backup-host/*.json|recovery_checksum_signal:*/backup-games/*.json)
        exit 74 ;;
    stage_install_interrupt:*/games/*.json|stage_restore_interrupt:*/backup-games/*.json)
        kill -TERM "$PPID"
        exit 74 ;;
    cleanup_term:*/backup-games/*.json)
        kill -TERM "$PPID"
        exit 74 ;;
    cleanup_int:*/backup-games/*.json)
        kill -INT "$PPID"
        exit 74 ;;
    restore_hup:*/backup-games/*.json)
        kill -HUP "$PPID"
        kill -HUP "$$" ;;
    broken_stderr_log_unwritable:*/backup-games/*.json)
        "$REAL_MKDIR" "${source_file%/backup-games/*}/recovery.log"
        exit 74 ;;
    append_recovery:*/backup-games/*.json)
        printf 'Earlier failure context\n' >"${source_file%/backup-games/*}/recovery.log"
        exit 74 ;;
    normal:*/games/*.json)
        case_root="$(cd "$(dirname "$0")/.." && pwd)"
        grep -F 'Temporary rollback backup: ' "$case_root/run.log" >/dev/null || exit 74 ;;
esac
if [[ "$STUB_SCENARIO" == backup_copy_fail && "$3" == */backup-host/ ]]; then exit 74; fi
if [[ "$STUB_SCENARIO" == backup_checksum_fail && "$3" == */backup-host/ ]]; then
    "$REAL_CP" "$@"
    printf '{"corrupted":true}\n' >"$3${source_file##*/}"
    exit 0
fi
if [[ "$STUB_SCENARIO" == candidate_disappears && "$3" == */backup-host/ ]]; then
    for fixture in "$TMPDIR"/partybox-goldens.*/games/game.json; do
        mv "$fixture" "$fixture.missing"
    done
fi
exec "$REAL_CP" "$@"
SH
    cat >"$root/bin/rm" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "$STUB_SCENARIO" == late_restore_signal || "$STUB_SCENARIO" == incomplete_backup_signal ]]; then
    if [[ "${3:-}" == *.probe ]]; then kill -TERM "$PPID"; fi
fi
if [[ "$STUB_SCENARIO" == staging_delete_fail && "${3:-}" == *.probe ]]; then exit 74; fi
if [[ "$STUB_SCENARIO" == host_restore_rm_fail ]]; then
    for target in "$@"; do
        if [[ "$target" == */PartyBoxTests/Fixtures/new-host.json ]]; then exit 74; fi
    done
fi
if [[ "$STUB_SCENARIO" == cleanup_removal_int && "${2:-}" == */golden-backups/partybox-goldens.* ]]; then
    "$REAL_RM" -rf "$2/backup-games"
    kill -INT "$PPID"
    exit 74
fi
exec "$REAL_RM" "$@"
SH
    cat >"$root/bin/mkdir" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "$STUB_SCENARIO" == early_setup_fail && "${2:-}" == */partybox-goldens.*/games ]]; then exit 74; fi
exec "$REAL_MKDIR" "$@"
SH
    cat >"$root/bin/cksum" <<'SH'
#!/bin/bash
set -euo pipefail
shopt -s nullglob
if [[ "$STUB_SCENARIO" == recovery_checksum_signal && -f "$TMPDIR/recorder-pid" ]]; then
    case_root="$(cd "$(dirname "$0")/.." && pwd)"
    logs=("$case_root"/.git/partybox-goldens/golden-backups/partybox-goldens.*/recovery.log)
    if [[ ${#logs[@]} -gt 0 ]]; then
        read -r recorder <"$TMPDIR/recorder-pid"
        kill -TERM "$recorder"
        kill -TERM "$$"
    fi
fi
exec "$REAL_CKSUM" "$@"
SH
    chmod +x "$root/bin/"*
}

run_script() {
    local root=$1 scenario=$2
    local -a command
    shift 2
    command=(env PATH="$root/bin:$PATH" TMPDIR="${TEST_SCRATCH_DIR:-$root/tmp}" STUB_SCENARIO="$scenario" \
        REAL_CP="$real_cp" REAL_RM="$real_rm" REAL_MKDIR="$real_mkdir" REAL_CKSUM="$real_cksum" \
        /bin/bash "$root/scripts/record-goldens.sh")
    if [[ "$scenario" == closed_stderr ]]; then
        "${command[@]}" "$@" >"$root/run.log" 2>&-
    elif [[ "$scenario" == broken_stdout ]]; then
        ( set +e; "${command[@]}" "$@" 2>"$root/run.log" | :; exit "${PIPESTATUS[0]}" )
    elif [[ "$scenario" == broken_stderr || "$scenario" == broken_stderr_log_unwritable ]]; then
        ( set +e; "${command[@]}" "$@" 2>&1 | :; exit "${PIPESTATUS[0]}" ) >"$root/run.log"
    else
        "${command[@]}" "$@" >"$root/run.log" 2>&1
    fi
}

signal_catchable() {
    local status=0
    /bin/bash -c 'trap "exit 42" "$1"; kill -s "$1" "$$"; exit 0' _ "$1" >/dev/null 2>&1 || status=$?
    [[ "$status" -eq 42 ]]
}

expect_status() {
    local root=$1 scenario=$2 expected=$3 actual=0
    shift 3
    run_script "$root" "$scenario" "$@" || actual=$?
    [[ "$actual" -eq "$expected" ]] || fail "$scenario exited $actual, expected $expected. See $root/run.log"
}

assert_content() {
    local path=$1 expected=$2 actual
    actual="$(cat "$path")" || fail "Could not read $path"
    [[ "$actual" == "$expected" ]] || fail "$path contained $actual, expected $expected"
}

assert_original() {
    local root=$1
    assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"original":"games"}'
    assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"original":"host"}'
    [[ ! -e "$root/PartyNet/Tests/PartyGamesTests/Fixtures/new-game.json" ]] || fail "Unexpected new game fixture"
    [[ ! -e "$root/PartyBoxTests/Fixtures/new-host.json" ]] || fail "Unexpected new host fixture"
}

assert_no_backups() {
    local root=$1
    local -a backups=("$root/.git/partybox-goldens/golden-backups"/partybox-goldens.*)
    [[ ${#backups[@]} -eq 0 ]] || fail "Unexpected retained backup in $root"
}

assert_no_temp() {
    local root=$1
    local -a outputs=("$root/tmp"/partybox-goldens.*)
    [[ ${#outputs[@]} -eq 0 ]] || fail "Temporary golden output remains in $root/tmp"
}

assert_no_staging() {
    local root=$1
    local -a staged=("$root/PartyNet/Tests/PartyGamesTests/Fixtures"/.partybox-fixture.* \
        "$root/PartyBoxTests/Fixtures"/.partybox-fixture.*)
    [[ ${#staged[@]} -eq 0 ]] || fail "Golden fixture staging files remain: ${staged[*]}"
}

assert_backup() {
    local root=$1 commands=${2:-verified} backup_path
    local -a backups=("$root/.git/partybox-goldens/golden-backups"/partybox-goldens.*)
    [[ ${#backups[@]} -eq 1 ]] || fail "Expected one retained backup in $root"
    backup_path=${backups[0]}
    assert_content "$backup_path/backup-games/game.json" '{"original":"games"}'
    assert_content "$backup_path/backup-host/unavailable-screen.json" '{"original":"host"}'
    grep -F "Golden backups retained at $backup_path" "$root/run.log" >/dev/null || fail "Backup path not reported: $(cat "$root/run.log")"
    grep -F "games: $backup_path/backup-games" "$root/run.log" >/dev/null || fail "Games backup not reported"
    grep -F "host: $backup_path/backup-host" "$root/run.log" >/dev/null || fail "Host backup not reported"
    if [[ "$commands" == verified ]]; then
        grep -F 'rsync -a --delete ' "$root/run.log" >/dev/null || fail "Recovery commands not reported"
        grep -F ' -maxdepth 1 -type f -name ' "$root/run.log" >/dev/null || fail "Staging cleanup command not reported"
    else
        assert_no_restore_commands "$root"
    fi
    grep -F 'Golden backups retained at ' "$backup_path/recovery.log" >/dev/null || fail "Recovery log not retained with backup"
}

assert_no_restore_commands() {
    local root=$1 log
    for log in "$root/run.log" "$root/.git/partybox-goldens/golden-backups"/partybox-goldens.*/recovery.log; do
        if [[ -f "$log" ]] && grep -Fq 'rsync -a --delete ' "$log"; then
            fail "Delete-capable restore commands appeared in $log"
        fi
    done
}

for scenario in recording_fail empty_output set_change; do
    make_case "$scenario"
    root="$test_root/$scenario"
    expect_status "$root" "$scenario" 1
    assert_original "$root"
    assert_no_backups "$root"
    assert_no_temp "$root"
done

make_case backup_copy_fail
root="$test_root/backup_copy_fail"
expect_status "$root" backup_copy_fail 1
assert_original "$root"
assert_no_backups "$root"
assert_no_temp "$root"

make_case backup_checksum_fail
root="$test_root/backup_checksum_fail"
expect_status "$root" backup_checksum_fail 1
assert_original "$root"
assert_no_backups "$root"
assert_no_temp "$root"
grep -F 'Golden backup verification failed' "$root/run.log" >/dev/null || fail "Backup verification failure was not reported"

root="$test_root/set_change"
expect_status "$root" set_change 0 --allow-set-change
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/new-game.json" '{"candidate":"new-game"}'
[[ ! -e "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" ]] || fail "Removed game fixture remains"
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"candidate":"host"}'
assert_no_backups "$root"
assert_no_temp "$root"

for scenario in verify_fail host_verify_fail closed_stderr broken_stderr scratch_lost \
    interrupt_term interrupt_quit interrupt_hup double_signal_cleanup_entry restore_hup; do
    make_case "$scenario"
    root="$test_root/$scenario"
    expected=1
    case "$scenario" in
        verify_fail) expected=76 ;;
        host_verify_fail) expected=77 ;;
        interrupt_term|double_signal_cleanup_entry) expected=143 ;;
        interrupt_quit)
            if ! signal_catchable QUIT; then printf 'Skipping SIGQUIT test because QUIT is ignored.\n'; continue; fi
            expected=131 ;;
        interrupt_hup)
            if ! signal_catchable HUP; then printf 'Skipping SIGHUP test because HUP is ignored.\n'; continue; fi
            expected=129 ;;
    esac
    if [[ "$scenario" == verify_fail || "$scenario" == host_verify_fail ]]; then
        mkdir "$root/caller-output"
        PARTYBOX_GOLDEN_OUTPUT_DIR="$root/caller-output" TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR="$root/caller-output" \
            expect_status "$root" "$scenario" "$expected"
        caller_files=("$root/caller-output"/*.json)
        [[ ${#caller_files[@]} -eq 0 ]] || fail "Verification wrote to the caller's recording directory"
    else
        expect_status "$root" "$scenario" "$expected"
    fi
    case "$scenario" in
        verify_fail) grep -Fq 'Swift verification stdout' "$root/run.log" || fail "Missing Swift log tail" ;;
        host_verify_fail) grep -Fq 'Xcode verification stdout' "$root/run.log" || fail "Missing Xcode log tail" ;;
    esac
    assert_original "$root"
    assert_no_backups "$root"
    assert_no_temp "$root"
    assert_no_staging "$root"
    if [[ "$scenario" == interrupt_term ]]; then expect_status "$root" normal 0; fi
done

if signal_catchable INT; then
    make_case interrupt_int
    root="$test_root/interrupt_int"
    expect_status "$root" interrupt_int 130
    assert_original "$root"
    assert_no_backups "$root"
    assert_no_temp "$root"
    assert_no_staging "$root"

    make_case cleanup_int
    root="$test_root/cleanup_int"
    expect_status "$root" cleanup_int 130
    assert_backup "$root" safe
    assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"candidate":"game"}'
    assert_no_temp "$root"
    assert_no_staging "$root"
    grep -F 'Fixture restoration interrupted.' "$root/run.log" >/dev/null || fail "SIGINT during restoration was not reported"

    make_case cleanup_removal_int
    root="$test_root/cleanup_removal_int"
    expect_status "$root" cleanup_removal_int 130
    assert_original "$root"
    assert_no_temp "$root"
    assert_no_staging "$root"
    backups=("$root/.git/partybox-goldens/golden-backups"/partybox-goldens.*)
    [[ ${#backups[@]} -eq 1 && ! -e "${backups[0]}/backup-games" ]] || fail "Expected a partially removed backup"
    grep -F "partially removed golden backup remains at ${backups[0]}" "$root/run.log" >/dev/null \
        || fail "Interrupted backup removal was not reported"
else
    printf 'Skipping SIGINT tests because INT is ignored.\n'
fi

make_case early_setup_fail
root="$test_root/early_setup_fail"
expect_status "$root" early_setup_fail 74
assert_original "$root"
assert_no_backups "$root"
assert_no_temp "$root"

make_case broken_stderr_log_unwritable
root="$test_root/broken_stderr_log_unwritable"
expect_status "$root" broken_stderr_log_unwritable 1
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"candidate":"game"}'
assert_no_temp "$root"
assert_no_staging "$root"
backups=("$root/.git/partybox-goldens/golden-backups"/partybox-goldens.*)
[[ ${#backups[@]} -eq 1 && -d "${backups[0]}/recovery.log" ]] || fail "Expected the backup to survive the log failure"

make_case append_recovery
root="$test_root/append_recovery"
expect_status "$root" append_recovery 1
assert_backup "$root"
backups=("$root/.git/partybox-goldens/golden-backups"/partybox-goldens.*)
grep -F 'Earlier failure context' "${backups[0]}/recovery.log" >/dev/null || fail "Earlier recovery log entry was lost"

make_case empty_backup
root="$test_root/empty_backup"
"$real_rm" "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json"
expect_status "$root" empty_backup 1 --allow-set-change
remaining_fixtures=("$root/PartyNet/Tests/PartyGamesTests/Fixtures"/*.json)
[[ ${#remaining_fixtures[@]} -eq 0 ]] || fail "Expected the original empty fixture set"
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"original":"host"}'
assert_no_backups "$root"
assert_no_temp "$root"
assert_no_staging "$root"

for scenario in games_install_copy_fail host_install_copy_fail; do
    make_case "$scenario"
    root="$test_root/$scenario"
    expect_status "$root" "$scenario" 1
    assert_original "$root"
    assert_no_backups "$root"
    assert_no_temp "$root"
    assert_no_staging "$root"
done

make_case candidate_disappears
root="$test_root/candidate_disappears"
expect_status "$root" candidate_disappears 1
assert_original "$root"
assert_no_backups "$root"
assert_no_temp "$root"
assert_no_staging "$root"

for scenario in backup_disappears backup_incomplete; do
    make_case "$scenario"
    root="$test_root/$scenario"
    expect_status "$root" "$scenario" 1 --allow-set-change
    assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/new-game.json" '{"candidate":"new-game"}'
    [[ ! -e "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" ]] || fail "Restore changed fixtures without an intact backup"
    assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"candidate":"host"}'
    grep -F 'Golden backup missing or incomplete' "$root/run.log" >/dev/null || fail "Missing backup was not reported"
    assert_no_temp "$root"
    assert_no_staging "$root"
done

make_case games_restore_copy_fail
root="$test_root/games_restore_copy_fail"
expect_status "$root" games_restore_copy_fail 1
assert_backup "$root"
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"candidate":"game"}'
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"original":"host"}'
assert_no_temp "$root"
assert_no_staging "$root"
if command -v zsh >/dev/null; then
    cleanup_command="$(sed -n 's/^  \(find .*\)$/\1/p' "$root/run.log")"
    [[ -n "$cleanup_command" ]] || fail "Staging cleanup command not reported"
    zsh -f -c "$cleanup_command" || fail "Recovery staging cleanup failed in zsh without matches"
fi

# A quick-check by size and mtime would accept both of these different files.
backups=("$root/.git/partybox-goldens/golden-backups"/partybox-goldens.*)
games="$root/PartyNet/Tests/PartyGamesTests/Fixtures"
host="$root/PartyBoxTests/Fixtures"
printf '{"original":"other"}\n' >"$games/game.json"
touch -r "${backups[0]}/backup-games/game.json" "$games/game.json"
printf '{"original":"xxxx"}\n' >"$host/unavailable-screen.json"
touch -r "${backups[0]}/backup-host/unavailable-screen.json" "$host/unavailable-screen.json"
for directory in "$games" "$host"; do
    printf 'untracked\n' >"$directory/.private.json"
    printf 'notes\n' >"$directory/notes.txt"
    mkdir "$directory/nested.json"
    printf 'nested\n' >"$directory/nested.json/data.json"
    touch "$directory/candidate-only.json"
done
restore_commands="$(sed -n 's/^  \(rsync .*\)$/\1/p' "${backups[0]}/recovery.log")"
[[ -n "$restore_commands" ]] || fail "Missing manual restore commands"
/bin/bash -e -c "$restore_commands"
assert_original "$root"
for directory in "$games" "$host"; do
    assert_content "$directory/.private.json" 'untracked'
    assert_content "$directory/notes.txt" 'notes'
    assert_content "$directory/nested.json/data.json" 'nested'
    [[ ! -e "$directory/candidate-only.json" ]] || fail "Manual restoration kept an extra fixture"
done

make_case host_restore_copy_fail
root="$test_root/host_restore_copy_fail"
expect_status "$root" host_restore_copy_fail 1
assert_backup "$root"
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"original":"games"}'
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"candidate":"host"}'
assert_no_temp "$root"
assert_no_staging "$root"

make_case host_restore_rm_fail
root="$test_root/host_restore_rm_fail"
expect_status "$root" host_restore_rm_fail 1 --allow-set-change
assert_backup "$root"
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"original":"games"}'
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"original":"host"}'
assert_content "$root/PartyBoxTests/Fixtures/new-host.json" '{"candidate":"new-host"}'
assert_no_temp "$root"
assert_no_staging "$root"

make_case stage_install_interrupt
root="$test_root/stage_install_interrupt"
expect_status "$root" stage_install_interrupt 143
assert_original "$root"
assert_no_backups "$root"
assert_no_temp "$root"
assert_no_staging "$root"

make_case stage_restore_interrupt
root="$test_root/stage_restore_interrupt"
expect_status "$root" stage_restore_interrupt 143
assert_backup "$root" safe
assert_no_temp "$root"
assert_no_staging "$root"
grep -F 'Fixture restoration interrupted.' "$root/run.log" >/dev/null || fail "Interrupted restoration was not reported"

make_case cleanup_term
root="$test_root/cleanup_term"
expect_status "$root" cleanup_term 143
assert_backup "$root" safe
assert_no_temp "$root"
assert_no_staging "$root"
grep -F 'Fixture restoration interrupted.' "$root/run.log" >/dev/null || fail "Cleanup interrupt handler did not run"

make_case incomplete_backup_signal
root="$test_root/incomplete_backup_signal"
expect_status "$root" incomplete_backup_signal 143
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"candidate":"game"}'
grep -Fq 'Golden backup missing or incomplete' "$root/run.log" || fail "Incomplete backup was not reported"
assert_no_restore_commands "$root"
assert_no_temp "$root"
assert_no_staging "$root"

make_case recovery_checksum_signal
root="$test_root/recovery_checksum_signal"
expect_status "$root" recovery_checksum_signal 143
assert_backup "$root" safe
grep -Fq 'Automatic fixture restoration was incomplete.' "$root/run.log" || fail "Recovery summary was lost"
assert_no_temp "$root"
assert_no_staging "$root"

make_case before_backup_check_signal
root="$test_root/before_backup_check_signal"
expect_status "$root" before_backup_check_signal 143
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"candidate":"game"}'
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"candidate":"host"}'
grep -Fq 'Backup integrity could not be confirmed' "$root/run.log" || fail "Unconfirmed backup was not reported"
backups=("$root/.git/partybox-goldens/golden-backups"/partybox-goldens.*)
[[ ${#backups[@]} -eq 1 ]] || fail "Expected the unchecked backup to be retained"
grep -Fq 'Backup integrity could not be confirmed' "${backups[0]}/recovery.log" || fail "Unconfirmed backup guidance was not saved"
assert_no_restore_commands "$root"
assert_no_temp "$root"
assert_no_staging "$root"

make_case late_restore_signal
root="$test_root/late_restore_signal"
expect_status "$root" late_restore_signal 143
assert_original "$root"
backups=("$root/.git/partybox-goldens/golden-backups"/partybox-goldens.*)
[[ ${#backups[@]} -eq 1 ]] || fail "Expected the backup to be retained after a staging interrupt"
grep -Fq 'Original golden fixtures restored.' "${backups[0]}/recovery.log" || fail "Successful restoration was not reported"
assert_no_restore_commands "$root"
assert_no_temp "$root"
assert_no_staging "$root"

make_case staging_delete_fail
root="$test_root/staging_delete_fail"
unrelated_stage="$root/PartyBoxTests/Fixtures/.partybox-fixture.other-run.probe"
touch "$unrelated_stage"
expect_status "$root" staging_delete_fail 1
assert_original "$root"
assert_no_restore_commands "$root"
assert_no_temp "$root"
backups=("$root/.git/partybox-goldens/golden-backups"/partybox-goldens.*)
[[ ${#backups[@]} -eq 1 ]] || fail "Expected the backup to be retained after staging deletion failed"
cleanup_command="$(sed -n 's/^  \(find .*\)$/\1/p' "$root/run.log")"
[[ -n "$cleanup_command" ]] || fail "Staging-only cleanup command not reported"
grep -Fxq "  $cleanup_command" "${backups[0]}/recovery.log" || fail "Staging-only cleanup command not saved"
current_stages=("$root/PartyNet/Tests/PartyGamesTests/Fixtures"/.partybox-fixture.partybox-goldens.* \
    "$root/PartyBoxTests/Fixtures"/.partybox-fixture.partybox-goldens.*)
[[ ${#current_stages[@]} -eq 2 ]] || fail "Expected both fixtures' staging files to remain"
cleanup_shell=/bin/bash
if command -v zsh >/dev/null; then cleanup_shell=zsh; fi
"$cleanup_shell" -c "$cleanup_command" || fail "Staging-only cleanup command failed"
for staged in "${current_stages[@]}"; do
    [[ ! -e "$staged" ]] || fail "This run's staging file remains: $staged"
done
[[ -f "$unrelated_stage" ]] || fail "Staging cleanup removed another run's file"
assert_original "$root"

make_case broken_stdout
root="$test_root/broken_stdout"
expect_status "$root" broken_stdout 0
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"candidate":"game"}'
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"candidate":"host"}'
assert_no_backups "$root"
assert_no_temp "$root"
assert_no_staging "$root"

make_case normal
root="$test_root/normal"
expect_status "$root" normal 0
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"candidate":"game"}'
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"candidate":"host"}'
assert_no_backups "$root"
assert_no_temp "$root"
assert_no_staging "$root"

make_case lock_checks
root="$test_root/lock_checks"
expect_status "$root" lock_checks 1
assert_content "$root/tmp/lock-checks" $'swift-record\nxcode-record\nswift\nxcode\nrollback'
assert_original "$root"
assert_no_backups "$root"
assert_no_temp "$root"
assert_no_staging "$root"
expect_status "$root" normal 0

make_case crash_after_install
root="$test_root/crash_after_install"
expect_status "$root" crash_after_install 137
games="$root/PartyNet/Tests/PartyGamesTests/Fixtures"
host="$root/PartyBoxTests/Fixtures"
backups=("$root/.git/partybox-goldens/golden-backups"/partybox-goldens.*)
[[ ${#backups[@]} -eq 1 ]] || fail "Forced termination did not retain a backup"
backup="${backups[0]}"
assert_content "$backup/backup-games/game.json" '{"original":"games"}'
assert_content "$backup/backup-host/unavailable-screen.json" '{"original":"host"}'
assert_content "$backup/games.manifest" "game.json $(cksum <"$backup/backup-games/game.json")"
assert_content "$backup/host.manifest" "unavailable-screen.json $(cksum <"$backup/backup-host/unavailable-screen.json")"
[[ -s "$backup/stage-tag" && ! -e "$backup/recovery.log" ]] || fail "Forced termination recovery metadata was unexpected"
expect_status "$root" lock_contender 1
grep -Fq "Retained golden backup needs review: $backup" "$root/run.log" || fail "Missing retained backup path"
[[ ! -e "$root/tmp/contender-started" ]] || fail "Recording started before crash recovery"
assert_content "$games/game.json" '{"candidate":"game"}'
assert_content "$host/unavailable-screen.json" '{"candidate":"host"}'
cp "$backup/backup-games/game.json" "$games/"
cp "$backup/backup-host/unavailable-screen.json" "$host/"
assert_original "$root"
mv "$backup" "$test_root/recovered-backup"
expect_status "$root" normal 0
assert_no_backups "$root"

make_case legacy_backup
root="$test_root/legacy_backup"
legacy_backup="$root/.verification/golden-backups/partybox-goldens.legacy"
mkdir -p "$legacy_backup"
expect_status "$root" lock_contender 1
grep -Fq "Retained golden backup needs review: $legacy_backup" "$root/run.log" || fail "Missing legacy backup path"
[[ -d "$legacy_backup" && ! -e "$root/tmp/contender-started" ]] || fail "Legacy backup did not prevent recording"
assert_original "$root"
assert_no_temp "$root"

make_case clean_while_locked
root="$test_root/clean_while_locked"
scratch="$test_root/clean-scratch"
mkdir -p "$scratch" "$root/.verification"
touch "$root/.verification/clean-me" "$root/run.log"
git -C "$root" add --force -- scripts bin PartyNet PartyBoxTests run.log
TEST_SCRATCH_DIR="$scratch" expect_status "$root" clean_while_locked 76
assert_content "$scratch/lock-checks" 'after-clean'
assert_original "$root"
assert_no_backups "$root"

make_case linked_worktree
root="$test_root/linked_worktree"
other="$test_root/linked-checkout"
git -C "$root" add --force -- scripts bin PartyNet PartyBoxTests
git -C "$root" -c user.name=PartyBox -c user.email=partybox@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit --quiet -m 'Create checkout for recording test'
git -C "$root" worktree add --quiet --detach "$other" HEAD
mkdir "$other/tmp"
LINKED_TEST_WORKTREE="$other" expect_status "$root" linked_worktree 76
other_git_dir="$(git -C "$other" rev-parse --absolute-git-dir)"
[[ -f "$other_git_dir/partybox-goldens/record-goldens.lock" ]] || fail "Missing linked worktree lock"
assert_content "$other/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"candidate":"game"}'
assert_content "$other/PartyBoxTests/Fixtures/unavailable-screen.json" '{"candidate":"host"}'
assert_original "$root"
assert_no_backups "$root"

echo "Golden recording safety cases passed."
