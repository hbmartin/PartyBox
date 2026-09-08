#!/bin/bash
set -euo pipefail

payload="$(cat)"
event_cwd="$(jq -r '.cwd // empty' <<<"$payload")"
[[ -n "$event_cwd" ]] || event_cwd="$PWD"
repo_root="$(git -C "$event_cwd" rev-parse --show-toplevel)"
session_id="$(jq -r '.session_id // "unknown-session"' <<<"$payload" | tr -c '[:alnum:]_.-' '_')"
turn_id="$(jq -r '.turn_id // "unknown-turn"' <<<"$payload" | tr -c '[:alnum:]_.-' '_')"
stop_hook_active="$(jq -r '.stop_hook_active // false' <<<"$payload")"
hook_root="$repo_root/.verification/hooks"
files_file="$hook_root/state/$session_id/$turn_id/files"
relevant_file="$hook_root/state/$session_id/$turn_id/relevant-files"
cache_dir="$hook_root/cache"

if [[ ! -s "$files_file" ]]; then
    printf '{}\n'
    exit 0
fi

mkdir -p "$(dirname "$relevant_file")" "$cache_dir" "$hook_root/runs" "$hook_root/artifacts"
: >"$relevant_file"

while IFS= read -r changed_path; do
    case "$changed_path" in
        *.md|*.markdown|Documentation/*|Docs/*|docs/*)
            continue
            ;;
        PartyBox/*|PartyBox\ Controller/*|PartyBoxTests/*|PartyBoxUITests/*|PartyBox\ ControllerTests/*|PartyBox\ ControllerUITests/*|PartyNet/*|Config/*|TestPlans/*|scripts/*|PartyBox.xcodeproj/*|.codex/*|.github/*|.gitignore|*.xcconfig)
            printf '%s\n' "$changed_path" >>"$relevant_file"
            ;;
    esac
done <"$files_file"

sort -u -o "$relevant_file" "$relevant_file"
if [[ ! -s "$relevant_file" ]]; then
    printf '{}\n'
    exit 0
fi

fingerprint="$({
    git -C "$repo_root" diff --binary HEAD -- \
        PartyBox 'PartyBox Controller' PartyBoxTests PartyBoxUITests \
        'PartyBox ControllerTests' 'PartyBox ControllerUITests' PartyNet Config TestPlans scripts \
        PartyBox.xcodeproj .codex .github .gitignore '*.xcconfig'
    git -C "$repo_root" ls-files --others --exclude-standard -- \
        PartyBox 'PartyBox Controller' PartyBoxTests PartyBoxUITests \
        'PartyBox ControllerTests' 'PartyBox ControllerUITests' PartyNet Config TestPlans scripts \
        PartyBox.xcodeproj .codex .github .gitignore '*.xcconfig' \
        | while IFS= read -r changed_path; do
            printf '%s\0' "$changed_path"
            shasum -a 256 "$repo_root/$changed_path"
        done
} | shasum -a 256 | awk '{print $1}')"

successful_fingerprints="$cache_dir/successful-fingerprints"
failed_fingerprint="$cache_dir/last-failed-fingerprint"
touch "$successful_fingerprints"
if grep -Fqx "$fingerprint" "$successful_fingerprints"; then
    printf '{}\n'
    exit 0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_name="$timestamp-${fingerprint:0:12}"
artifact_dir="$hook_root/artifacts/$run_name"
log_path="$hook_root/runs/$run_name.log"
mkdir -p "$artifact_dir"

set +e
PARTYBOX_ARTIFACT_DIR="$artifact_dir" "$repo_root/scripts/verify.sh" normal >"$log_path" 2>&1
verify_status=$?
set -e

if [[ $verify_status -eq 0 ]]; then
    printf '%s\n' "$fingerprint" >>"$successful_fingerprints"
    sort -u -o "$successful_fingerprints" "$successful_fingerprints"
    if [[ -f "$failed_fingerprint" ]]; then
        recorded_failure="$(<"$failed_fingerprint")"
        if [[ "$recorded_failure" == "$fingerprint" ]]; then
            : >"$failed_fingerprint"
        fi
    fi
    printf '{}\n'
    exit 0
fi

previous_failure=""
[[ -f "$failed_fingerprint" ]] && previous_failure="$(<"$failed_fingerprint")"
printf '%s\n' "$fingerprint" >"$failed_fingerprint"
relative_log="${log_path#"$repo_root/"}"
relative_artifacts="${artifact_dir#"$repo_root/"}"
failure_message="PartyBox normal verification failed (status $verify_status). Review $relative_log and artifacts in $relative_artifacts."

if [[ "$previous_failure" != "$fingerprint" && "$stop_hook_active" != "true" ]]; then
    jq -n --arg reason "$failure_message Fix the failure, then rerun verification before stopping." \
        '{decision: "block", reason: $reason}'
else
    jq -n --arg warning "$failure_message Automatic continuation was suppressed because this unchanged failure already received one retry." \
        '{systemMessage: $warning}'
fi
