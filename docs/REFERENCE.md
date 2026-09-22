# PartyBox Reference

[Setup guide](../QUICKSTART.md) · [Network troubleshooting](TROUBLESHOOTING.md)

### Protocol and timing constants

From `PartyNet/Sources/PartyNet/Protocol/PartyNetConstants.swift`:

| Constant | Value | Meaning |
|---|---|---|
| `serviceType` | `_partybox._tcp` | Bonjour service |
| `protocolVersion` | `2` | Advertised as `v` in the TXT record |
| `maximumControllers` | `8` | Hard cap on connected phones |
| `reconnectGrace` | 15 s | How long the host holds a seat after a drop |
| `clientReconnectWindow` | 30 s | How long the phone keeps retrying |
| `helloTimeout` | 5 s | Handshake deadline |
| `udpReadyTimeout` | 1 s | No UDP ack in this window → TCP fallback |
| `udpIdleTimeout` | 5 s | UDP flow considered dead |
| `tcpFallbackInterval` | 33 ms | Input rate once fallen back to TCP (~30 Hz) |
| `pingInterval` / `pingTimeout` | 2 s / 6 s | Liveness probe on the control channel |

Active paddle seats: **4** (arena edges, in order: bottom, top, left, right).
Lives per player: **3**. Normal input rate: **~60 Hz** (16 ms).

### Host controls

| Action | Apple TV (Siri Remote) | Mac (keyboard) | Any phone |
|---|---|---|---|
| Navigate | Swipe / click a direction | ↑ ↓ ← → | ▲ ▼ buttons |
| Select | Click touch surface | Return or Space | **SELECT** |
| Back | Menu button | Esc | **BACK** |

### Debug-only launch arguments

**All of these are compiled out of Release builds.** Set them in
**Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments Passed On Launch**.

Host (`PartyBox`):

| Argument | Effect |
|---|---|
| `--host-name <name>` | Override the advertised Bonjour name |
| `--bot-count <0…8>` | Spawn N loopback bot controllers — lets you drive a full match on one machine with no phones |
| `--seed <UInt64>` | Deterministic Pong physics |
| `--disable-animations` | Remove SwiftUI transitions |
| `--disable-effects` | Mute the arcade sounds |
| `--scenario <name>` | Static UI fixture, **networking disabled**: `empty-lobby`, `menu`, `four-way-match`, `game-over` (any other value, e.g. `four-player-lobby`, gives a populated lobby) |
| `--freeze-scenario` | Keep a host `--scenario` screen fixed during screenshot UI tests; ordinary scenario fixtures remain navigable |
| `--ui-testing` | Marks a UI-test run |

Controller (`PartyBox Controller` target):

| Argument | Effect |
|---|---|
| `--host <HOST:PORT>` | Add a direct-address row to the picker, bypassing Bonjour (see [§9.8](TROUBLESHOOTING.md#98-last-resort-escape-hatch-connect-by-address)) |
| `--display-name <name>` | Force the player name |
| `--controller-id <UUID>` | Force the persistent identity |
| `--defaults-suite <name>` | Isolate `UserDefaults` |
| `--disable-effects` | Suppress haptics |
| `--disable-animations`, `--seed`, `--ui-testing` | As above |
| `--scenario <name>` | Static UI fixture: `empty-picker`, `populated-picker`, `connecting`, `menu`, `paddle-bottom`/`-top`/`-left`/`-right`, `spectator`, `game-over`, `reconnecting`, `full-rejection`, `version-rejection`, `local-network-denial`, `connection-loss` |

> `--bot-count 4 --host-name "Test PartyBox"` on the host is the fastest way to confirm a full four-player
> match works before anyone shows up.

### Messages you might see, and what they mean

| Message | Where | Meaning |
|---|---|---|
| `Ready for controllers` | Host status | Listeners bound, Bonjour advertising |
| `Could not start: …` | Host status | Listener failed — permissions or firewall |
| `<name> joined` / `<name> left the party` | Host status | Roster changes |
| `Waiting 15 seconds for <name>…` | Host status | Reconnect grace running |
| `This PartyBox already has 8 controllers.` | Phone, **CAN'T JOIN** | Party is full |
| `Controller version is incompatible with host protocol N.` | Phone, **CAN'T JOIN** | Rebuild both apps |
| `This controller was replaced by another connection using the same identity.` | Phone, **CAN'T JOIN** | Same controller ID joined elsewhere |
| `The host could not understand this controller.` | Phone, **CAN'T JOIN** | Malformed handshake |
| `The host is no longer reachable.` | Phone, **CONNECTION LOST** | Host went away |
| `Local Network access is off…` | Phone, discovery card | See [§9.3](TROUBLESHOOTING.md#93-local-network-permission-on-the-iphone) |
| `The host address is invalid.` | Phone | Bad `--host` argument ([§9.8](TROUBLESHOOTING.md#98-last-resort-escape-hatch-connect-by-address)) |

---
