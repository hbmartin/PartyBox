#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
record_root="$(mktemp -d "${TMPDIR:-/tmp}/partybox-goldens.XXXXXX")"
trap 'rm -rf "$record_root"' EXIT

games_output="$record_root/games"
host_output="$record_root/host"
mkdir -p "$games_output" "$host_output"

games_log="$record_root/games.log"
host_log="$record_root/host.log"
if env PARTYBOX_GOLDEN_OUTPUT_DIR="$games_output" \
    swift test --package-path "$ROOT_DIR/PartyNet" --filter ControllerScreenGoldenTests \
    >"$games_log" 2>&1; then
    echo "Expected the PartyGames recording test to report candidate generation." >&2
    exit 1
fi
if ! rg -q 'Golden candidates generated' "$games_log"; then
    tail -80 "$games_log" >&2
    exit 1
fi

if env TEST_RUNNER_PARTYBOX_GOLDEN_OUTPUT_DIR="$host_output" \
    xcodebuild -project "$ROOT_DIR/PartyBox.xcodeproj" -scheme PartyBox \
    -testPlan PartyBox-Normal -destination 'platform=macOS' \
    '-only-testing:PartyBoxTests/PartyBoxTests/oversizedNestedControllerLayoutFallsBackToASendableScreen()' \
    ENABLE_APP_SANDBOX=NO test >"$host_log" 2>&1; then
    echo "Expected the PartyBox recording test to report candidate generation." >&2
    exit 1
fi
if ! rg -q 'Golden candidate generated' "$host_log"; then
    tail -80 "$host_log" >&2
    exit 1
fi

games_fixtures="$ROOT_DIR/PartyNet/Tests/PartyGamesTests/Fixtures"
host_fixtures="$ROOT_DIR/PartyBoxTests/Fixtures"
if ! diff -u \
    <(find "$games_fixtures" -maxdepth 1 -name '*.json' -exec basename {} \; | sort) \
    <(find "$games_output" -maxdepth 1 -name '*.json' -exec basename {} \; | sort); then
    echo "PartyGames candidate filenames do not match the committed fixture set." >&2
    exit 1
fi
if ! diff -u \
    <(find "$host_fixtures" -maxdepth 1 -name '*.json' -exec basename {} \; | sort) \
    <(find "$host_output" -maxdepth 1 -name '*.json' -exec basename {} \; | sort); then
    echo "PartyBox candidate filenames do not match the committed fixture set." >&2
    exit 1
fi

for fixture in "$games_fixtures"/*.json; do
    cp "$games_output/$(basename "$fixture")" "$fixture"
done
for fixture in "$host_fixtures"/*.json; do
    cp "$host_output/$(basename "$fixture")" "$fixture"
done

swift test --package-path "$ROOT_DIR/PartyNet" --filter ControllerScreenGoldenTests
xcodebuild -project "$ROOT_DIR/PartyBox.xcodeproj" -scheme PartyBox \
    -testPlan PartyBox-Normal -destination 'platform=macOS' \
    '-only-testing:PartyBoxTests/PartyBoxTests/oversizedNestedControllerLayoutFallsBackToASendableScreen()' \
    test

echo "Golden fixtures recorded and verified. Review the fixture diff before committing."
