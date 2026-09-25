#!/bin/bash
set -euo pipefail
shopt -s nullglob

source_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/record-goldens.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/partybox-record-test.XXXXXX")"
test_root="$(cd "$test_root" && pwd)"
real_cp="$(command -v cp)"
real_rm="$(command -v rm)"
trap '"$real_rm" -rf "$test_root"' EXIT

fail() { echo "$*" >&2; exit 1; }

make_case() {
    local root="$test_root/$1"
    mkdir -p "$root/scripts" "$root/bin" "$root/tmp" \
        "$root/PartyNet/Tests/PartyGamesTests/Fixtures" "$root/PartyBoxTests/Fixtures"
    "$real_cp" "$source_script" "$root/scripts/record-goldens.sh"
    printf '{"original":"games"}\n' >"$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json"
    printf '{"original":"host"}\n' >"$root/PartyBoxTests/Fixtures/unavailable-screen.json"

    cat >"$root/bin/swift" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ -n "${PARTYBOX_GOLDEN_OUTPUT_DIR:-}" ]]; then
    if [[ "$STUB_SCENARIO" == empty_output ]]; then
        exit 0
    elif [[ "$STUB_SCENARIO" == set_change ]]; then
        printf '{"candidate":"new-game"}\n' >"$PARTYBOX_GOLDEN_OUTPUT_DIR/new-game.json"
    else
        printf '{"candidate":"game"}\n' >"$PARTYBOX_GOLDEN_OUTPUT_DIR/game.json"
    fi
    if [[ "$STUB_SCENARIO" == recording_fail ]]; then exit 1; fi
else
    if [[ "$STUB_SCENARIO" == interrupt_int || "$STUB_SCENARIO" == second_interrupt ]]; then
        kill -INT "$PPID"
        exit 0
    elif [[ "$STUB_SCENARIO" == interrupt_term ]]; then
        kill -TERM "$PPID"
        exit 0
    elif [[ "$STUB_SCENARIO" == verify_fail || "$STUB_SCENARIO" == games_restore_copy_fail \
        || "$STUB_SCENARIO" == host_restore_copy_fail ]]; then
        exit 1
    fi
fi
SH
    cat >"$root/bin/xcodebuild" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ -n "${TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR:-}" ]]; then
    if [[ "$STUB_SCENARIO" == host_restore_rm_fail ]]; then
        printf '{"candidate":"new-host"}\n' >"$TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR/new-host.json"
    else
        printf '{"candidate":"host"}\n' >"$TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR/unavailable-screen.json"
    fi
elif [[ "$STUB_SCENARIO" == host_verify_fail || "$STUB_SCENARIO" == host_restore_rm_fail ]]; then
    exit 1
fi
SH
    cat >"$root/bin/cp" <<'SH'
#!/bin/bash
set -euo pipefail
source_file=$2
case "$STUB_SCENARIO:$source_file" in
    games_install_copy_fail:*/games/*.json|host_install_copy_fail:*/host/*.json)
        exit 74 ;;
    games_restore_copy_fail:*/backup-games/*.json|host_restore_copy_fail:*/backup-host/*.json)
        exit 74 ;;
    second_interrupt:*/backup-games/*.json)
        kill -INT "$PPID"
        exit 74 ;;
esac
if [[ "$STUB_SCENARIO" == backup_copy_fail && "$3" == */backup-host/ ]]; then exit 74; fi
exec "$REAL_CP" "$@"
SH
    cat >"$root/bin/rm" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "$STUB_SCENARIO" == host_restore_rm_fail ]]; then
    for target in "$@"; do
        if [[ "$target" == */PartyBoxTests/Fixtures/new-host.json ]]; then exit 74; fi
    done
fi
exec "$REAL_RM" "$@"
SH
    chmod +x "$root/bin/swift" "$root/bin/xcodebuild" "$root/bin/cp" "$root/bin/rm"
}

run_script() {
    local root=$1 scenario=$2
    shift 2
    env PATH="$root/bin:$PATH" TMPDIR="$root/tmp" STUB_SCENARIO="$scenario" \
        REAL_CP="$real_cp" REAL_RM="$real_rm" \
        /bin/bash "$root/scripts/record-goldens.sh" "$@" >"$root/run.log" 2>&1
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
    local -a backups=("$root/.verification/golden-backups"/partybox-goldens.*)
    [[ ${#backups[@]} -eq 0 ]] || fail "Unexpected retained backup in $root"
}

assert_no_temp() {
    local root=$1
    local -a outputs=("$root/tmp"/partybox-goldens.*)
    [[ ${#outputs[@]} -eq 0 ]] || fail "Temporary golden output remains in $root/tmp"
}

assert_backup() {
    local root=$1
    local -a backups=("$root/.verification/golden-backups"/partybox-goldens.*)
    [[ ${#backups[@]} -eq 1 ]] || fail "Expected one retained backup in $root"
    backup_path=${backups[0]}
    assert_content "$backup_path/backup-games/game.json" '{"original":"games"}'
    assert_content "$backup_path/backup-host/unavailable-screen.json" '{"original":"host"}'
    grep -F "Golden backups retained at $backup_path" "$root/run.log" >/dev/null || fail "Backup path not reported: $(cat "$root/run.log")"
    grep -F "games: $backup_path/backup-games" "$root/run.log" >/dev/null || fail "Games backup not reported"
    grep -F "host: $backup_path/backup-host" "$root/run.log" >/dev/null || fail "Host backup not reported"
    grep -F 'rsync -a --delete ' "$root/run.log" >/dev/null || fail "Recovery commands not reported"
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

root="$test_root/set_change"
expect_status "$root" set_change 0 --allow-set-change
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/new-game.json" '{"candidate":"new-game"}'
[[ ! -e "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" ]] || fail "Removed game fixture remains"
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"candidate":"host"}'
assert_no_backups "$root"
assert_no_temp "$root"

for scenario in verify_fail host_verify_fail interrupt_int interrupt_term; do
    make_case "$scenario"
    root="$test_root/$scenario"
    expected=1
    if [[ "$scenario" == interrupt_int ]]; then expected=130; fi
    if [[ "$scenario" == interrupt_term ]]; then expected=143; fi
    expect_status "$root" "$scenario" "$expected"
    assert_original "$root"
    assert_no_backups "$root"
    assert_no_temp "$root"
done

for scenario in games_install_copy_fail host_install_copy_fail; do
    make_case "$scenario"
    root="$test_root/$scenario"
    expect_status "$root" "$scenario" 1
    assert_original "$root"
    assert_no_backups "$root"
    assert_no_temp "$root"
done

make_case games_restore_copy_fail
root="$test_root/games_restore_copy_fail"
expect_status "$root" games_restore_copy_fail 1
assert_backup "$root"
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"candidate":"game"}'
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"original":"host"}'
assert_no_temp "$root"

make_case host_restore_copy_fail
root="$test_root/host_restore_copy_fail"
expect_status "$root" host_restore_copy_fail 1
assert_backup "$root"
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"original":"games"}'
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"candidate":"host"}'
assert_no_temp "$root"

make_case host_restore_rm_fail
root="$test_root/host_restore_rm_fail"
expect_status "$root" host_restore_rm_fail 1 --allow-set-change
assert_backup "$root"
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"original":"games"}'
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"original":"host"}'
assert_content "$root/PartyBoxTests/Fixtures/new-host.json" '{"candidate":"new-host"}'
assert_no_temp "$root"

make_case second_interrupt
root="$test_root/second_interrupt"
expect_status "$root" second_interrupt 130
assert_backup "$root"
grep -F 'Recovery backup:' "$root/run.log" >/dev/null || fail "Backup location was not printed before restoration"

make_case normal
root="$test_root/normal"
expect_status "$root" normal 0
assert_content "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" '{"candidate":"game"}'
assert_content "$root/PartyBoxTests/Fixtures/unavailable-screen.json" '{"candidate":"host"}'
assert_no_backups "$root"
assert_no_temp "$root"

echo "Golden recording safety cases passed."
