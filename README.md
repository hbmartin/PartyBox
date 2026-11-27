# PartyBox

A local-network party game for the living room. One **host** — an Apple TV or a Mac — runs the game on the
big screen; up to **eight iPhones** join over Wi-Fi and act as the controllers. Gameplay runs over
Bonjour on your LAN and works offline. Configured TestFlight builds send native crash diagnostics
to Sentry.

The library has eight fast arcade games: **Four-Way Pong**, **Snake Pit**, **Last Light**,
**Bumper Brawl**, **Paint Rush**, **Sky Hop**, **Hot Fuse**, and the **Turbo Loop** racer. Every game
supports one to eight players (Pong seats four and rotates the rest in from a winner-stays bench), bots can
fill the room, and a three-event **Party Cup** awards persistent trophies. Touch is the controller default,
with an optional swipe (trackpad) touch style; players can also opt into calibrated motion controls.
Phones also provide brief, gentle private color and haptic cues—never torch or distributed audio.

> **▶ New here? Read [QUICKSTART.md](QUICKSTART.md).** It covers setup and signing, both host paths
> (Apple TV and Mac), getting the controller onto your friends' phones, and a step-by-step playtest.
> Use [network troubleshooting](docs/TROUBLESHOOTING.md) when connection problems arise.

The [release guide](docs/RELEASE.md) covers TestFlight uploads and Sentry symbols for iPhone, Apple TV, and Mac.

## Targets

| Target | Product | Platforms |
|---|---|---|
| `PartyBox` | The host app | tvOS 26+ **and** macOS 26+ (one target, native on both) |
| `PartyBox Controller` | PartyPad, the iPhone controller | iOS 26+, iPhone only, portrait |
| `PartyNet` | Local Swift package | The shared transport, used by both apps |
| `PartyGames` | Library target in `PartyNet/` | Game implementations and headless macOS tests, used by the host |

Requires **Xcode 26.3+** / Swift 6.2. The transport is built on the Swift-native Network framework API
(`NetworkListener`, `NetworkBrowser`, `Coder`) from the 26.x SDKs, so there is no back-deployment below
tvOS/iOS/macOS 26.

## How it works

Discovery is Bonjour (`_partybox._tcp`). Each phone then holds two channels to the host: a **JSON-over-TCP
control channel** for handshake, roster, layout pushes and menu actions, and a **binary UDP channel** for
60 Hz input, with automatic fallback to TCP if UDP goes quiet. The host is authoritative for all game
state. Peer-to-peer/AWDL is deliberately disabled — everyone shares one real Wi-Fi/LAN subnet.

## Layout

```
PartyBox/              Host app (tvOS + macOS): Cup flow and SwiftUI screens
PartyBox Controller/   PartyPad iPhone app: touch/motion controls, private cues, trophies
PartyNet/              Shared protocol, transport, game runtime, and PartyGames package target
PartyFault/            Apache-2.0 generic Network.framework fault proxy library + CLI
Config/                Info.plists (Bonjour service + Local Network usage strings)
TestPlans/             Normal / ASan / TSan / Soak test plans for both apps
scripts/verify.sh      Automated build, test, sanitizer and soak suite
```

## Verification automation

GitHub Actions runs Bash syntax checks, ShellCheck, the golden recording and distribution script tests,
and JSON validation on Linux for pull requests and pushes to `main`. Changes under `PartyNet/` or to
`.github/workflows/party-net-tests.yml` also run the Swift package tests on a hosted macOS runner,
including gameplay, protocol policies, and the UDP queue limit. The hosted selection skips the
`NetworkIntegrationTests` suite. The full transport suite and Apple app and simulator tests run on
a development Mac through `scripts/verify.sh normal`.

On a development Mac, `scripts/verify.sh normal` is enforced by the project-local Codex `Stop` hook
after relevant source, test, project, configuration, asset, or verification-harness edits. A
`PostToolUse` hook records files changed through `apply_patch`; documentation-only turns are skipped,
successful working-tree fingerprints are cached, and an unchanged failure can trigger at most one
automatic continuation. Hook state, logs, and artifacts live under the ignored `.verification/`
directory.

Project-local hooks are inactive until you use `/hooks` to review and trust their current definition.
Codex invalidates that trust when the hook definition changes. See the supported
[Codex Hooks mechanism](https://learn.chatgpt.com/docs/hooks.md) for the review flow and event contract.

The soak, ASan, and TSan profiles remain manual. Run `scripts/verify.sh soak` when you want the load and
fault-injection soak, or `scripts/verify.sh all` for the complete local acceptance suite. Load runs
require both client transmission metrics and host-observed changing input for every controller; there
is no scheduled soak job.
The normal gate also runs the local package's `PartyGamesTests` on tvOS through Xcode's
`PartyNet-Package` scheme because the app test-plan picker does not expose that package test target.

To update controller-screen JSON fixtures, run `scripts/record-goldens.sh` from a Git checkout on a
development Mac. Each worktree allows one recorder at a time, including during rollback. A second
invocation exits immediately. The recorder generates candidates in a temporary directory, installs
them only after both recording tests pass, and reruns ordinary comparisons. If a comparison fails,
the script prints the end of its verification log and validates both backups before restoring the previous fixtures.
The script prints the temporary rollback backup path before installing candidates. A missing or
incomplete backup stops automatic restoration without deleting fixtures.
If restoration fails or is interrupted, the script reports the backup location and appends recovery
information to `recovery.log` when it can write there. It prints exact restore commands only after a
fresh integrity check of both backup folders. Use the printed commands after inspecting the backup
and fixture diff. If the check failed or was interrupted, recover the originals from Git or another
verified copy.

The printed restore commands recopy the visible top-level JSON fixtures even when their size and
timestamp match, and remove extra visible top-level JSON fixtures. Hidden files and subdirectories
are preserved. If both fixture sets are restored and staging cleanup fails, use the printed cleanup
command to remove temporary files from that recording run.

The lock and new backups live under `partybox-goldens/` in the worktree Git directory shown by
`git rev-parse --absolute-git-dir`. They survive `git clean -fdx`. The recorder also stops for
backups left in the legacy `.verification/golden-backups/` directory. Keep retained backups in place
until recovery is confirmed, and put off checkout cleanup while you need a legacy backup.

After a forced termination, `recovery.log` may be absent. With the recorder stopped, inspect the
fixture diff and set `backup` to the retained path printed by the script. Run this from the checkout
in Bash when both sets need restoration. It verifies both backups before restoring either set.

```bash
backup=/absolute/path/to/partybox-goldens.backup
fixture_manifest() (
    export LC_ALL=C
    shopt -s nullglob
    cd -- "$1" || exit 1
    for fixture in *.json; do
        printf '%s ' "$fixture"
        cksum <"$fixture" || exit 1
    done
)
restore=(rsync -a --delete --ignore-times --exclude='.*' --exclude='*/' --include='*.json' --exclude='*')
if root=$(git rev-parse --show-toplevel) &&
    [[ -d "$root/PartyNet/Tests/PartyGamesTests/Fixtures" && -d "$root/PartyBoxTests/Fixtures" ]] &&
    [[ -f "$backup/games.manifest" && -f "$backup/host.manifest" ]] &&
    games_manifest=$(fixture_manifest "$backup/backup-games") &&
    host_manifest=$(fixture_manifest "$backup/backup-host") &&
    [[ "$games_manifest" == "$(<"$backup/games.manifest")" &&
       "$host_manifest" == "$(<"$backup/host.manifest")" ]]; then
    "${restore[@]}" "$backup/backup-games/" "$root/PartyNet/Tests/PartyGamesTests/Fixtures/" &&
    "${restore[@]}" "$backup/backup-host/" "$root/PartyBoxTests/Fixtures/"
else
    echo 'Backup integrity could not be confirmed. Recover from Git or another verified copy.' >&2
fi
```

Inspect the recovered fixture diff, then remove only hidden staging files that match
`.partybox-fixture.<stage-tag>.*` in the two fixture directories. The backup's `stage-tag` file
identifies the run. Move or remove the backup after confirming recovery so recording can resume.

Use `scripts/record-goldens.sh --allow-set-change` when adding, renaming, or removing
fixture files; without that flag, only existing fixture values can change. The recording command
temporarily disables the macOS host app sandbox for its Xcode test invocation; normal builds and
tests retain their configured sandbox. Review the fixture diff before committing. The old
`PARTYBOX_RECORD_GOLDENS` and `PARTYGAMES_RECORD_GOLDENS` environment flags are no longer used.

## Docs

- **[QUICKSTART.md](QUICKSTART.md)** — build it, install it, and play it.
- **[Network troubleshooting](docs/TROUBLESHOOTING.md)** — diagnose discovery and connection problems.
- **[App reference](docs/REFERENCE.md)** — controls, launch arguments, and protocol constants.
- **[PartyFault/README.md](PartyFault/README.md)** — generic TCP/UDP impairment proxy and JSON control socket.
- [CANDIDATE STACK.md](CANDIDATE%20STACK.md) — the chosen architecture and reliability advice.
- [CHECKLIST.md](CHECKLIST.md) — landscape survey behind the transport decision.
- [REFERENCES.md](REFERENCES.md) — prior art on pairing, identity and reconnection.

## Note on security

The control channel is unencrypted and there is no join code: anyone on the same LAN with the controller
app can join. Run it on a network you trust.
