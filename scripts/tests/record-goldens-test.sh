#!/bin/bash
set -euo pipefail

source_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/record-goldens.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/partybox-record-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

make_case() {
    local name=$1 root="$test_root/$1"
    mkdir -p "$root/scripts" "$root/bin" \
        "$root/PartyNet/Tests/PartyGamesTests/Fixtures" "$root/PartyBoxTests/Fixtures"
    cp "$source_script" "$root/scripts/record-goldens.sh"
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
    [[ "$STUB_SCENARIO" != recording_fail ]]
else
    if [[ "$STUB_SCENARIO" == interrupted ]]; then
        kill -TERM "$PPID"
        exit 0
    fi
    [[ "$STUB_SCENARIO" != verify_fail && "$STUB_SCENARIO" != restore_copy_fail && "$STUB_SCENARIO" != restore_remove_fail ]]
fi
SH
    cat >"$root/bin/xcodebuild" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ -n "${TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR:-}" ]]; then
    printf '{"candidate":"host"}\n' >"$TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR/unavailable-screen.json"
else
    [[ "$STUB_SCENARIO" != host_verify_fail ]]
fi
SH
    cat >"$root/bin/cp" <<'SH'
#!/bin/bash
if [[ "$STUB_SCENARIO" == restore_copy_fail && "$1" == */backup-games/*.json ]]; then
    exit 23
fi
exec /bin/cp "$@"
SH
    cat >"$root/bin/rm" <<'SH'
#!/bin/bash
if [[ "$STUB_SCENARIO" == restore_remove_fail && "$1" == -f && "$2" == */Fixtures/game.json ]]; then
    exit 23
fi
exec /bin/rm "$@"
SH
    chmod +x "$root/bin/swift" "$root/bin/xcodebuild" "$root/bin/cp" "$root/bin/rm"
}

run_script() {
    local root=$1 scenario=$2
    shift 2
    env PATH="$root/bin:$PATH" TMPDIR="$root" STUB_SCENARIO="$scenario" \
        bash "$root/scripts/record-goldens.sh" "$@" >"$root/run.log" 2>&1
}

assert_original() {
    local root=$1
    [[ "$(cat "$root/PartyNet/Tests/PartyGamesTests/Fixtures/game.json")" == '{"original":"games"}' ]]
    [[ "$(cat "$root/PartyBoxTests/Fixtures/unavailable-screen.json")" == '{"original":"host"}' ]]
    [[ ! -e "$root/PartyNet/Tests/PartyGamesTests/Fixtures/new-game.json" ]]
}

assert_retained_backup() {
    local root=$1 record_root
    record_root="$(find "$root" -maxdepth 1 -type d -name 'partybox-goldens.*' -print -quit)"
    [[ -n "$record_root" ]]
    [[ "$(cat "$record_root/backup-games/game.json")" == '{"original":"games"}' ]]
    [[ "$(cat "$record_root/backup-host/unavailable-screen.json")" == '{"original":"host"}' ]]
    grep -Fq "Fixture restoration failed; backups retained at $record_root." "$root/run.log"
}

make_case recording_fail
if run_script "$test_root/recording_fail" recording_fail; then
    echo "A failing recording test installed candidates." >&2
    exit 1
fi
assert_original "$test_root/recording_fail"

make_case empty_output
if run_script "$test_root/empty_output" empty_output; then
    echo "An empty recording installed candidates." >&2
    exit 1
fi
assert_original "$test_root/empty_output"

make_case set_change
if run_script "$test_root/set_change" set_change; then
    echo "A filename change succeeded without --allow-set-change." >&2
    exit 1
fi
assert_original "$test_root/set_change"
run_script "$test_root/set_change" set_change --allow-set-change
[[ -e "$test_root/set_change/PartyNet/Tests/PartyGamesTests/Fixtures/new-game.json" ]]
[[ ! -e "$test_root/set_change/PartyNet/Tests/PartyGamesTests/Fixtures/game.json" ]]

for scenario in verify_fail host_verify_fail interrupted; do
    make_case "$scenario"
    if run_script "$test_root/$scenario" "$scenario"; then
        echo "$scenario did not fail verification." >&2
        exit 1
    fi
    assert_original "$test_root/$scenario"
done

for scenario in restore_copy_fail restore_remove_fail; do
    make_case "$scenario"
    if run_script "$test_root/$scenario" "$scenario"; then
        echo "$scenario unexpectedly succeeded." >&2
        exit 1
    fi
    assert_retained_backup "$test_root/$scenario"
done

make_case normal
run_script "$test_root/normal" normal
[[ "$(cat "$test_root/normal/PartyNet/Tests/PartyGamesTests/Fixtures/game.json")" == '{"candidate":"game"}' ]]
[[ "$(cat "$test_root/normal/PartyBoxTests/Fixtures/unavailable-screen.json")" == '{"candidate":"host"}' ]]
echo "Golden recording safety cases passed."
