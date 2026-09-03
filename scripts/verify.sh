#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly PROFILE="${1:-normal}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
readonly TIMESTAMP
readonly ARTIFACT_DIR="${PARTYBOX_ARTIFACT_DIR:-$ROOT_DIR/.verification/$TIMESTAMP}"
readonly PROJECT="$ROOT_DIR/PartyBox.xcodeproj"

IOS_UDID=""
TVOS_UDID=""
IOS_DESTINATION=""
TVOS_DESTINATION=""
FAULT_PID=""
FAULT_READY=""
FAULT_ADDRESS=""
CONTROL_ADDRESS=""

mkdir -p "$ARTIFACT_DIR"

for tool in jq plutil swift xcodebuild xcrun; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Required tool not found: $tool" >&2
        exit 1
    }
done

cleanup() {
    local status=$?
    pkill -x PartyBox >/dev/null 2>&1 || true
    pkill -x PartyBoxUITests-Runner >/dev/null 2>&1 || true
    if [[ -n "$FAULT_PID" ]] && kill -0 "$FAULT_PID" 2>/dev/null; then
        kill "$FAULT_PID" 2>/dev/null || true
        wait "$FAULT_PID" 2>/dev/null || true
    fi
    if [[ -n "$IOS_UDID" ]]; then
        xcrun simctl shutdown "$IOS_UDID" >/dev/null 2>&1 || true
        xcrun simctl delete "$IOS_UDID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$TVOS_UDID" ]]; then
        xcrun simctl shutdown "$TVOS_UDID" >/dev/null 2>&1 || true
        xcrun simctl delete "$TVOS_UDID" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

usage() {
    echo "usage: scripts/verify.sh [normal|asan|tsan|soak|all]"
}

case "$PROFILE" in
    normal|asan|tsan|soak|all) ;;
    *) usage; exit 2 ;;
esac

run_logged() {
    local label=$1
    shift
    echo "==> $label"
    "$@" 2>&1 | tee "$ARTIFACT_DIR/$label.log"
}

run_xcode() {
    local label=$1
    shift
    local log="$ARTIFACT_DIR/$label.log"
    echo "==> $label"
    set +e
    if command -v xcbeautify >/dev/null 2>&1; then
        xcodebuild -collect-test-diagnostics never "$@" 2>&1 | tee "$log" | xcbeautify
    else
        xcodebuild -collect-test-diagnostics never "$@" 2>&1 | tee "$log"
    fi
    local status=${PIPESTATUS[0]}
    set -e
    return "$status"
}

latest_runtime() {
    local platform=$1
    xcrun simctl list runtimes --json | jq -r --arg platform "$platform" '
        [.runtimes[] | select(.isAvailable and (.identifier | contains($platform)))]
        | sort_by(.version) | last | .identifier // empty
    '
}

ensure_ios_destination() {
    if [[ -n "$IOS_DESTINATION" ]]; then return; fi
    if [[ -n "${PARTYBOX_IOS_DESTINATION:-}" ]]; then
        IOS_DESTINATION="$PARTYBOX_IOS_DESTINATION"
        return
    fi
    local runtime device_type
    runtime="$(latest_runtime 'iOS')"
    [[ -n "$runtime" ]] || { echo "No available iOS Simulator runtime." >&2; exit 1; }
    device_type="$(xcrun simctl list devicetypes --json | jq -r '
        [.devicetypes[] | select(.productFamily == "iPhone" and (.name | startswith("iPhone")))]
        | first | .identifier // empty
    ')"
    [[ -n "$device_type" ]] || { echo "No iPhone simulator device type." >&2; exit 1; }
    IOS_UDID="$(xcrun simctl create "PartyBox Verify iPhone $$" "$device_type" "$runtime")"
    xcrun simctl boot "$IOS_UDID"
    xcrun simctl bootstatus "$IOS_UDID" -b
    IOS_DESTINATION="platform=iOS Simulator,id=$IOS_UDID"
}

ensure_tvos_destination() {
    if [[ -n "$TVOS_DESTINATION" ]]; then return; fi
    if [[ -n "${PARTYBOX_TVOS_DESTINATION:-}" ]]; then
        TVOS_DESTINATION="$PARTYBOX_TVOS_DESTINATION"
        return
    fi
    local runtime device_type
    runtime="$(latest_runtime 'tvOS')"
    [[ -n "$runtime" ]] || { echo "No available tvOS Simulator runtime." >&2; exit 1; }
    device_type="$(xcrun simctl list devicetypes --json | jq -r \
        '.devicetypes[] | select(.productFamily == "Apple TV") | .identifier' | head -1)"
    [[ -n "$device_type" ]] || { echo "No Apple TV simulator device type." >&2; exit 1; }
    TVOS_UDID="$(xcrun simctl create "PartyBox Verify Apple TV $$" "$device_type" "$runtime")"
    xcrun simctl boot "$TVOS_UDID"
    xcrun simctl bootstatus "$TVOS_UDID" -b
    TVOS_DESTINATION="platform=tvOS Simulator,id=$TVOS_UDID"
}

start_fault_rig() {
    if [[ -n "$FAULT_PID" ]] && kill -0 "$FAULT_PID" 2>/dev/null; then return; fi
    run_logged partyfault-build swift build --package-path "$ROOT_DIR/PartyNet" --product partyfault
    run_logged partyload-build swift build --package-path "$ROOT_DIR/PartyNet" --product partyload
    FAULT_READY="$ARTIFACT_DIR/partyfault-ready.json"
    "$ROOT_DIR/PartyNet/.build/debug/partyfault" serve \
        --ready-file "$FAULT_READY" --seed 42 >"$ARTIFACT_DIR/partyfault.log" 2>&1 &
    FAULT_PID=$!
    for _ in $(seq 1 200); do
        [[ -s "$FAULT_READY" ]] && break
        kill -0 "$FAULT_PID" 2>/dev/null || { cat "$ARTIFACT_DIR/partyfault.log"; exit 1; }
        sleep 0.05
    done
    [[ -s "$FAULT_READY" ]] || { echo "partyfault did not become ready" >&2; exit 1; }
    local host tcp_port control_port
    host="$(plutil -extract host raw "$FAULT_READY")"
    tcp_port="$(plutil -extract tcpPort raw "$FAULT_READY")"
    control_port="$(plutil -extract controlPort raw "$FAULT_READY")"
    FAULT_ADDRESS="$host:$tcp_port"
    CONTROL_ADDRESS="127.0.0.1:$control_port"
}

fault_control() {
    "$ROOT_DIR/PartyNet/.build/debug/partyfault" control --address "$CONTROL_ADDRESS" "$@"
}

normal() {
    run_logged partynet-tests swift test --package-path "$ROOT_DIR/PartyNet"
    ensure_ios_destination
    ensure_tvos_destination
    start_fault_rig

    pkill -x PartyBox >/dev/null 2>&1 || true
    run_xcode macos-normal -project "$PROJECT" -scheme PartyBox -testPlan PartyBox-Normal \
        -destination "${PARTYBOX_MACOS_DESTINATION:-platform=macOS}" \
        -resultBundlePath "$ARTIFACT_DIR/macos-normal.xcresult" test
    run_xcode tvos-normal -project "$PROJECT" -scheme PartyBox -testPlan PartyBox-Normal \
        -destination "$TVOS_DESTINATION" \
        -resultBundlePath "$ARTIFACT_DIR/tvos-normal.xcresult" test
    run_xcode ios-normal -project "$PROJECT" \
        -scheme "PartyBox Controller" -testPlan PartyBoxController-Normal \
        -destination "$IOS_DESTINATION" \
        -resultBundlePath "$ARTIFACT_DIR/ios-normal.xcresult" \
        PARTYFAULT_HOST="$FAULT_ADDRESS" test

    fault_control metrics >"$ARTIFACT_DIR/fault-metrics.json"
    run_xcode release-macos -project "$PROJECT" -scheme PartyBox \
        -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
    run_xcode release-tvos -project "$PROJECT" -scheme PartyBox \
        -configuration Release -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
    run_xcode release-ios -project "$PROJECT" -scheme "PartyBox Controller" \
        -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
    run_logged partynet-release swift build --package-path "$ROOT_DIR/PartyNet" -c release
}

asan() {
    ensure_ios_destination
    run_logged partynet-asan swift test --package-path "$ROOT_DIR/PartyNet" --sanitize address
    pkill -x PartyBox >/dev/null 2>&1 || true
    run_xcode macos-asan -project "$PROJECT" -scheme PartyBox -testPlan PartyBox-ASan \
        -destination "${PARTYBOX_MACOS_DESTINATION:-platform=macOS}" \
        -resultBundlePath "$ARTIFACT_DIR/macos-asan.xcresult" test
    run_xcode ios-asan -project "$PROJECT" -scheme "PartyBox Controller" \
        -testPlan PartyBoxController-ASan -destination "$IOS_DESTINATION" \
        -resultBundlePath "$ARTIFACT_DIR/ios-asan.xcresult" test
}

tsan() {
    ensure_ios_destination
    run_logged partynet-tsan swift test --package-path "$ROOT_DIR/PartyNet" --sanitize thread
    pkill -x PartyBox >/dev/null 2>&1 || true
    run_xcode macos-tsan -project "$PROJECT" -scheme PartyBox -testPlan PartyBox-TSan \
        -destination "${PARTYBOX_MACOS_DESTINATION:-platform=macOS}" \
        -resultBundlePath "$ARTIFACT_DIR/macos-tsan.xcresult" test
    run_xcode ios-tsan -project "$PROJECT" -scheme "PartyBox Controller" \
        -testPlan PartyBoxController-TSan -destination "$IOS_DESTINATION" \
        -resultBundlePath "$ARTIFACT_DIR/ios-tsan.xcresult" test
}

soak() {
    local iterations="${PARTYBOX_SOAK_ITERATIONS:-25}"
    local seconds="${PARTYBOX_SOAK_SECONDS:-300}"
    local fault_seconds="${PARTYBOX_FAULT_SECONDS:-30}"
    ensure_ios_destination
    start_fault_rig

    pkill -x PartyBox >/dev/null 2>&1 || true
    run_xcode macos-soak -project "$PROJECT" -scheme PartyBox -testPlan PartyBox-Soak \
        -destination "${PARTYBOX_MACOS_DESTINATION:-platform=macOS}" \
        -resultBundlePath "$ARTIFACT_DIR/macos-soak.xcresult" test
    run_xcode ios-soak -project "$PROJECT" -scheme "PartyBox Controller" \
        -testPlan PartyBoxController-Soak -destination "$IOS_DESTINATION" \
        -resultBundlePath "$ARTIFACT_DIR/ios-soak.xcresult" test

    for iteration in $(seq 1 "$iterations"); do
        run_logged "partynet-soak-$iteration" swift test --package-path "$ROOT_DIR/PartyNet"
    done
    run_logged partyload-stable "$ROOT_DIR/PartyNet/.build/debug/partyload" \
        --address "$FAULT_ADDRESS" --count 8 --hz 60 --seconds "$seconds"

    fault_control udp --drop 1 --delay-ms 0 --jitter-ms 0 --reorder-window 1 \
        >"$ARTIFACT_DIR/fault-udp-loss.json"
    run_logged partyload-udp-loss "$ROOT_DIR/PartyNet/.build/debug/partyload" \
        --address "$FAULT_ADDRESS" --count 8 --hz 60 --seconds "$fault_seconds"
    fault_control metrics >"$ARTIFACT_DIR/fault-udp-loss-metrics.json"
    fault_control reset >"$ARTIFACT_DIR/fault-recovery.json"
    run_logged partyload-recovery "$ROOT_DIR/PartyNet/.build/debug/partyload" \
        --address "$FAULT_ADDRESS" --count 8 --hz 60 --seconds "$fault_seconds"
    fault_control metrics >"$ARTIFACT_DIR/fault-recovery-metrics.json"
    fault_control reset >/dev/null
    fault_control udp --drop 0.15 --delay-ms 12 --jitter-ms 7 --reorder-window 2 \
        >"$ARTIFACT_DIR/fault-seeded.json"
    run_logged partyload-seeded-faults "$ROOT_DIR/PartyNet/.build/debug/partyload" \
        --address "$FAULT_ADDRESS" --count 8 --hz 60 --seconds "$fault_seconds"
    fault_control metrics >"$ARTIFACT_DIR/fault-seeded-metrics.json"

    run_logged partynet-tcp-cut swift test --package-path "$ROOT_DIR/PartyNet" \
        --filter 'TCPCutReconnectsToSameHostInstance'
    run_logged partynet-host-restart swift test --package-path "$ROOT_DIR/PartyNet" \
        --filter 'upstreamRestartReturnsExistingControllerToPicker'
    fault_control metrics >"$ARTIFACT_DIR/fault-soak-metrics.json"
}

case "$PROFILE" in
    normal) normal ;;
    asan) asan ;;
    tsan) tsan ;;
    soak) soak ;;
    all) normal; asan; tsan; soak ;;
esac

echo "Verification artifacts: $ARTIFACT_DIR"
