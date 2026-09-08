#!/bin/bash
set -euo pipefail

payload="$(cat)"
event_cwd="$(jq -r '.cwd // empty' <<<"$payload")"
[[ -n "$event_cwd" ]] || event_cwd="$PWD"
repo_root="$(git -C "$event_cwd" rev-parse --show-toplevel)"
session_id="$(jq -r '.session_id // "unknown-session"' <<<"$payload" | tr -c '[:alnum:]_.-' '_')"
turn_id="$(jq -r '.turn_id // "unknown-turn"' <<<"$payload" | tr -c '[:alnum:]_.-' '_')"
state_dir="$repo_root/.verification/hooks/state/$session_id/$turn_id"
files_file="$state_dir/files"

mkdir -p "$state_dir"
touch "$files_file"

jq -r '.tool_input.command // empty' <<<"$payload" \
    | sed -nE \
        -e 's/^\*\*\* (Add|Update|Delete) File: //p' \
        -e 's/^\*\*\* Move to: //p' \
    | while IFS= read -r changed_path; do
        if [[ "$changed_path" == "$repo_root/"* ]]; then
            changed_path="${changed_path#"$repo_root/"}"
        fi
        [[ -n "$changed_path" && "$changed_path" != /* && "$changed_path" != ../* ]] || continue
        printf '%s\n' "$changed_path" >>"$files_file"
    done

sort -u -o "$files_file" "$files_file"
