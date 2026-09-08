# PartyBox

A local-network party game for the living room. One **host** — an Apple TV or a Mac — runs the game on the
big screen; up to **eight iPhones** join over Wi-Fi and act as the controllers. No accounts, no servers,
no internet: just Bonjour on your LAN.

The first (and currently only) game is **Four-Way Pong**: four players on the four edges of the arena,
three lives each, winner stays, everyone else waits in a spectator queue.

> **▶ New here? Read [QUICKSTART.md](QUICKSTART.md).** It covers setup and signing, both host paths
> (Apple TV and Mac), getting the controller onto your friends' phones, a step-by-step playtest
> walkthrough, and network troubleshooting.

## Targets

| Target | Product | Platforms |
|---|---|---|
| `PartyBox` | The host app | tvOS 26+ **and** macOS 26+ (one target, native on both) |
| `PartyBox Controller` | The iPhone controller | iOS 26+, iPhone only, portrait |
| `PartyNet` | Local Swift package | The shared transport, used by both apps |

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
PartyBox/              Host app (tvOS + macOS): coordinator, SwiftUI screens, SpriteKit Pong
PartyBox Controller/   iPhone app: host picker, paddle/menu/spectator layouts
PartyNet/              Swift package: protocol, transport, host + client, partyload/partyfault tools
Config/                Info.plists (Bonjour service + Local Network usage strings)
TestPlans/             Normal / ASan / TSan / Soak test plans for both apps
scripts/verify.sh      Automated build, test, sanitizer and soak suite
```

## Verification automation

GitHub Actions runs portable static checks on pull requests and pushes to `main`: Bash syntax,
ShellCheck, and JSON validation for test plans and Codex hook configuration. It deliberately does not
claim to build or test the Apple targets because this project does not use paid GitHub macOS runners.

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
fault-injection soak, or `scripts/verify.sh all` for the complete local acceptance suite; there is no
scheduled soak job.

## Docs

- **[QUICKSTART.md](QUICKSTART.md)** — build it, install it, play it, debug the network.
- [CANDIDATE STACK.md](CANDIDATE%20STACK.md) — the chosen architecture and reliability advice.
- [CHECKLIST.md](CHECKLIST.md) — landscape survey behind the transport decision.
- [REFERENCES.md](REFERENCES.md) — prior art on pairing, identity and reconnection.

## Note on security

The control channel is unencrypted and there is no join code: anyone on the same LAN with the controller
app can join. Run it on a network you trust.
