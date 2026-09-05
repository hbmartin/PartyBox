# PartyBox Quickstart

Everything you need to get PartyBox running in your living room, with your friends' iPhones as the
controllers. Two host options are covered end to end: **an Apple TV** (the intended setup) and **a Mac**
(handy when you don't have an Apple TV, or when you want the host in front of you while you debug).

---

## 1. What you're setting up

PartyBox is a **star topology**. One host owns the game; every phone is a dumb-ish controller.

```
                    Bonjour: _partybox._tcp
                              │
        ┌─────────────────────┴─────────────────────┐
        │                                           │
   ┌────▼─────────────────┐              ┌──────────▼──────────┐
   │  PartyBox (host)     │◄─ TCP  ──────┤  PartyBox Controller│  ×8
   │  Apple TV  or  Mac   │   control    │  iPhone             │
   │  • owns game state   │              │  • picks a host     │
   │  • renders the arena │◄─ UDP  ──────┤  • sends 60 Hz input│
   └──────────────────────┘   input      └─────────────────────┘
```

| | Target | Runs on |
|---|---|---|
| **Host** | `PartyBox` | Apple TV (tvOS 26) **or** Mac (macOS 26) — one target, two platforms |
| **Controller** | `PartyBox Controller` | iPhone (iOS 26), portrait only |

Facts worth knowing before you start:

- **8 controllers max.** The 9th phone is rejected with *"This PartyBox already has 8 controllers."*
- **4 play at a time.** Paddles are assigned to the arena edges in order: bottom, top, left, right.
  Controllers 5–8 sit in a spectator queue.
- **1 player is enough to start** — a solo match is a practice run.
- **One game right now:** Four-Way Pong. Three lives each, winner stays.
- **No encryption and no join code.** Anyone on the same LAN who has the app can join your party. Use a
  network you trust; don't run this on conference Wi-Fi.

---

## 2. Requirements

### Toolchain

- **Xcode 26.3 or newer** (this repo was built with Xcode 26.3 / build 17C529, Swift 6.2.4).
  Verify: `xcodebuild -version && swift --version`
- Network access on first build — Swift Package Manager resolves `pointfreeco/swift-dependencies` (pinned
  to exactly `1.10.0`) plus its transitive dependencies.
- A **paid Apple Developer Program** membership. You will be installing on real hardware and, most likely,
  distributing to friends over TestFlight.

### Hardware and OS floors

These are hard floors. The networking layer uses the Swift-native Network framework types
(`NetworkListener`, `NetworkBrowser`, `Coder`) introduced in the 26.x SDKs, so **there is no
back-deployment path**.

| Device | Minimum OS | Notes |
|---|---|---|
| Apple TV | **tvOS 26.0** | Apple TV 4K recommended. Ethernet strongly recommended (see §5). |
| Mac (as host) | **macOS 26.0 (Tahoe)** | Compiles on older macOS, but the built app **will not launch**. Check with `sw_vers`. |
| iPhone | **iOS 26.0** | iPhone only — the controller target is `TARGETED_DEVICE_FAMILY = 1`. No iPad. |

> **If your Mac is on macOS 15 or earlier**, you can still build and ship to an Apple TV and to iPhones.
> You just can't use the Mac itself as the host. Use §5 (Apple TV) and skip §6.

### Network

- One Wi-Fi network (or Wi-Fi + Ethernet bridged by the same router) shared by the host and every phone.
- **Peer-to-peer / AWDL is deliberately disabled** in the transport (`peerToPeerIncluded(false)`
  everywhere). There is no direct device-to-device fallback: everyone must be on the same subnet and mDNS
  must reach across it.
- Client isolation ("AP isolation", "guest network") must be **off**.

---

## 3. Clone, open, resolve

```bash
git clone <your-fork-url> PartyBox
cd PartyBox
open PartyBox.xcodeproj
```

There is **no `.xcworkspace`** — open the `.xcodeproj` directly. `PartyNet` is a local Swift package
referenced from the project, so it builds as part of the project; you never need to open it separately.

On first open, Xcode resolves packages. If it stalls, force it with
**File ▸ Packages ▸ Resolve Package Versions**, or from the terminal:

```bash
xcodebuild -list -project PartyBox.xcodeproj    # resolves packages and lists schemes
```

You should see these schemes:

```
PartyBox              ← the host app (tvOS + macOS)
PartyBox Controller   ← the iPhone app
partyfault            ┐
partyload             ├ PartyNet package tools, not needed for a normal party
PartyNet              │
PartyNetTestSupport   ┘
```

Repo layout, briefly:

| Path | What it is |
|---|---|
| `PartyBox/` | Host app: `PartyBoxApp.swift`, `ContentView.swift`, `HostCoordinator.swift`, `Game/` |
| `PartyBox Controller/` | iPhone app: `ContentView.swift`, `ControllerCoordinator.swift` |
| `PartyNet/` | Local SPM package — all networking, shared by both apps |
| `Config/` | The two hand-maintained Info.plists (Bonjour + Local Network strings) |
| `scripts/verify.sh` | The automated verification suite (not needed to play) |

---

## 4. Sign both app targets — do this once

Neither app target has a `DEVELOPMENT_TEAM` committed, and the bundle identifiers belong to the original
author. Fix both before you build to a device.

For **each** of the two app targets — `PartyBox` and `PartyBox Controller`:

1. Select the project in the navigator ▸ pick the target ▸ **Signing & Capabilities**.
2. Leave **Automatically manage signing** checked.
3. Choose your **Team**.
4. Change the **Bundle Identifier** to something in your own namespace:

   | Target | Committed value | Change to |
   |---|---|---|
   | `PartyBox` | `me.haroldmartin.PartyBox` | `com.yourname.PartyBox` |
   | `PartyBox Controller` | `me.haroldmartin.PartyBox-Controller` | `com.yourname.PartyBox-Controller` |

   (The four test targets have their own IDs derived from these; Xcode will flag them if it needs them
   changed too. You only need the test targets signed if you plan to run the test suites on device.)

You do **not** need to add any capabilities or entitlement files:

- There are no `.entitlements` files in the repo, and none are needed.
- **No multicast entitlement is required.** Discovery is plain Bonjour/mDNS through `NWBrowser`, plus
  unicast TCP and UDP. `com.apple.developer.networking.multicast` does not apply.
- The macOS host's sandbox networking is generated from build settings already in the project
  (`ENABLE_APP_SANDBOX`, `ENABLE_INCOMING_NETWORK_CONNECTIONS[sdk=macosx*]`,
  `ENABLE_OUTGOING_NETWORK_CONNECTIONS[sdk=macosx*]`, `ENABLE_HARDENED_RUNTIME[sdk=macosx*]`).
- The two Info.plists in `Config/` already declare what iOS/tvOS/macOS need in order to talk on the LAN:

  ```xml
  <key>NSBonjourServices</key>
  <array><string>_partybox._tcp</string></array>
  <key>NSLocalNetworkUsageDescription</key>
  <string>…</string>
  ```

  Without these you get **silent** discovery failure, so don't strip them.

---

## 5. Host path A — Apple TV

This is the setup the game was designed for.

### 5.1 Put the Apple TV on Ethernet (recommended)

From `CANDIDATE STACK.md`:

> **Put the Apple TV on Ethernet.** It removes the host from Wi-Fi contention entirely and is the cheapest
> reliability win available to you.

Ethernet works fine as long as the wired and wireless sides are the **same subnet** and your router
forwards mDNS between them. Most home routers do; some mesh systems don't (see §9).

### 5.2 Pair the Apple TV with Xcode (over the network)

Apple TV has no cable option — pairing is always over the network.

1. Put the Mac and the Apple TV on the **same network**.
2. On the Apple TV: **Settings ▸ Remotes and Devices ▸ Remote App and Devices**. Leave this screen open —
   it says *"Searching…"*.
3. In Xcode: **Window ▸ Devices and Simulators** (⇧⌘2). The Apple TV appears in the left column.
4. Select it and click **Pair**. Xcode shows a field; the Apple TV shows a **6-digit code**. Type it in.
5. The device turns from a "not paired" state to a normal, connected device. Xcode will then download
   symbols — wait for **"Ready"** before running.

Also enable **Settings ▸ Privacy & Security ▸ Developer Mode** on tvOS if Xcode prompts for it, and
restart the Apple TV when asked.

### 5.3 Build and run the host

1. Scheme selector: **`PartyBox`**.
2. Destination: your Apple TV (not "Any tvOS Device", not a simulator).
3. **⌘R**.

> **Don't use the tvOS Simulator for a real party.** The simulator does not do real local-network
> discovery, so phones will never find it. Run on the actual Apple TV.

### 5.4 Approve Local Network access on tvOS

The first launch shows a system prompt using the string from `Config/PartyBox-Info.plist`:

> *"PartyBox uses your local network so nearby iPhones can join as game controllers."*

**Allow it.** If you dismiss it, phones will never see the host. To fix later:
**Settings ▸ Apps ▸ PartyBox ▸ Local Network**, or **Settings ▸ Privacy & Security ▸ Local Network**.

### 5.5 What you should see

The TV shows the lobby:

```
              LOCAL ARCADE
               PARTYBOX
  Open PartyBox Controller on iPhone and choose this host

              [ Living-Room's PartyBox ]        ← your host name

   ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
   │ P1     │ │ P2     │ │ P3     │ │ P4     │
   │ OPEN   │ │ OPEN   │ │ OPEN   │ │ OPEN   │
   │AVAILABLE│ │AVAILABLE│ │AVAILABLE│ │AVAILABLE│
   └────────┘ └────────┘ └────────┘ └────────┘
   ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
   │ P5 …   │ │ P6 …   │ │ P7 …   │ │ P8 …   │
   └────────┘ └────────┘ └────────┘ └────────┘

     ● WAITING FOR A CONTROLLER
       Ready for controllers
```

The **host name** is generated from the machine's hostname:
`ProcessInfo.processInfo.hostName` minus `.local`, plus `"'s PartyBox"`. So an Apple TV named
"Living Room" advertises as **`Living-Room's PartyBox`**. That exact string is what phones will show in
their picker. Rename the Apple TV in **Settings ▸ General ▸ About ▸ Name** if you want something friendlier.

The status line under the dot is your health readout. `Ready for controllers` means the listeners bound
and Bonjour is advertising. Anything starting `Could not start:` means the host failed — see §9.

### 5.6 Siri Remote controls on the host

| Remote | Action |
|---|---|
| Swipe / click **up, down, left, right** | Navigate the menu |
| **Select** (click the touch surface) | Confirm / start |
| **Menu / Back** | Back one screen |

You can also drive all of this from any connected phone — you never actually need to pick up the remote
once someone has joined.

---

## 6. Host path B — Mac

Same target, same code, native macOS app (not Catalyst, not "Designed for iPad").

### 6.1 Check your macOS version first

```bash
sw_vers    # ProductVersion must be 26.x
```

`MACOSX_DEPLOYMENT_TARGET = 26.0`. On macOS 15 or earlier the app compiles but macOS refuses to launch it.
There is no supported workaround; use the Apple TV path instead.

### 6.2 Build and run

1. Scheme selector: **`PartyBox`**.
2. Destination: **My Mac**.
3. **⌘R**.

The app opens a single 1280×720 window titled **PartyBox** (`Window("PartyBox", id: "partybox-main")`).
Full-screen it (⌃⌘F) if the Mac is plugged into a TV.

### 6.3 Approve two prompts on macOS

The Mac host is **sandboxed with the hardened runtime enabled**, and it both listens and connects. Expect:

1. **Local Network** — *"PartyBox uses your local network so nearby iPhones can join as game controllers."*
   Allow. Fix later in **System Settings ▸ Privacy & Security ▸ Local Network**.
2. **Incoming connections firewall alert** — *"Do you want the application PartyBox to accept incoming
   network connections?"* Click **Allow**. If you never saw it, check
   **System Settings ▸ Network ▸ Firewall ▸ Options** and make sure PartyBox is set to
   *Allow incoming connections* (or that "Block all incoming connections" is off).

There are no port numbers to open. Both listeners bind **kernel-assigned ephemeral ports**; the TCP port
is published in the Bonjour record and the UDP port is handed to each phone during the handshake.

### 6.4 Keyboard controls on the Mac host

The macOS build wires hidden keyboard shortcuts (`ContentView.keyboardButtons`, `#if os(macOS)`):

| Key | Action |
|---|---|
| **Return** or **Space** | Select |
| **↑ ↓ ← →** | Navigate |
| **Esc** | Back |
| Click anywhere in the window | Select |

The window has to be focused for these to register. If nothing happens, click the window once.

### 6.5 Running the host without Xcode

For an actual party you don't want Xcode attached (the debugger pauses the game when you switch away).
Build once, then launch the product directly:

```bash
xcodebuild -project PartyBox.xcodeproj -scheme PartyBox \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build build

open "build/Build/Products/Release/PartyBox.app"
```

Or simply **Product ▸ Build For ▸ Running**, then **Product ▸ Show Build Folder in Finder** and
double-click `PartyBox.app`.

> A **Release** build disables every debug launch argument listed in §10 — that's intentional. Use Debug
> builds while you're testing, Release for the party.

---

## 7. Get the controller onto your friends' iPhones

The controller app is a normal iPhone app. Two ways to distribute it.

### 7.1 Phones you have in your hand — install straight from Xcode

1. Plug the iPhone into the Mac (or pair it over Wi-Fi via **Window ▸ Devices and Simulators ▸
   Connect via network**).
2. On the phone, enable **Settings ▸ Privacy & Security ▸ Developer Mode**, toggle it on, and restart when
   prompted. (Developer Mode only appears after the phone has been connected to Xcode at least once.)
3. Scheme: **`PartyBox Controller`**. Destination: that iPhone. **⌘R**.
4. Repeat per phone. Xcode will register each device in your team's provisioning profile automatically.

Note the per-account device limit (100 devices per device type per membership year) — fine for a party,
worth knowing if you're doing this repeatedly.

### 7.2 Everyone else — TestFlight

This is the sane path for a real party where friends arrive with their own phones.

1. In App Store Connect, create an app record using your controller bundle ID
   (e.g. `com.yourname.PartyBox-Controller`).
2. In Xcode: scheme **`PartyBox Controller`**, destination **Any iOS Device (arm64)**, then
   **Product ▸ Archive**.
3. In the Organizer: **Distribute App ▸ TestFlight (and App Store)** ▸ upload.
4. Once processing finishes, add testers:
   - **Internal testing** — up to 100 App Store Connect users on your team, available immediately, no
     review.
   - **External testing** — up to 10,000 testers via a public link, but the **first build needs Beta App
     Review** (usually a day or so). Do this before party day, not during it.
5. Send friends the TestFlight link. They install the TestFlight app, tap the link, install PartyBox
   Controller.

Because you are only shipping the **controller** through TestFlight, the host app never leaves your Mac or
Apple TV — that's the only piece you personally have to run.

### 7.3 What friends need to know

- The app is **iPhone only** and **portrait only**. It will run letterboxed on iPad but was not designed
  for it.
- On first launch it asks for **Local Network** access. They must tap **Allow** or nothing will be found.
- Their name and controller identity persist between launches (`UserDefaults` keys
  `partybox.displayName` and `partybox.controllerID`) — so reconnecting after a crash puts them back in
  the same seat with the same color.

---

## 8. Run the party — step by step

Follow this in order the first time. Each step names what should appear, so you know exactly where it
broke if it does.

### Step 1 — Start the host

Launch `PartyBox` on the Apple TV or Mac. It starts advertising immediately on launch; there is no
"start hosting" button.

✅ **You should see:** the lobby, the host name badge, eight `OPEN` slots, and the status line
`Ready for controllers`.

❌ If the status reads `Could not start: …`, the listeners failed to bind. Jump to §9.

### Step 2 — First phone opens the controller

✅ **You should see** on the phone:

```
IPHONE CONTROLLER
PARTYBOX

YOUR NAME
[ Player                    ]  [ SAVE ]

CHOOSE A HOST                       ◌
        ((•))
  Looking for PartyBox on your local network…
```

Approve the Local Network prompt when it appears.

### Step 3 — Set a name

Type a name in the field and tap **SAVE** (or hit return). It's saved to the device and reused next time.
You can also rename mid-party while connected — the TV roster updates live.

### Step 4 — Pick the host

Within a second or two the host appears as a row with a 📺 icon, the host name, and **READY TO JOIN**.
Tap it.

✅ Phone: **CONNECTING** ▸ then **YOU'RE IN** with a green check, the roster, and an **OPEN GAME MENU**
button.
✅ TV: slot **P1** fills in with the player's name and color, `ACTIVE SEAT`, and the status line flips to
`<name> joined`. The footer changes to **PRESS SELECT TO CHOOSE A GAME**.

❌ Nothing appears after ~4 seconds? The phone shows a **NO HOSTS FOUND** card with **TRY AGAIN** and
**OPEN SETTINGS**. Go to §9.
❌ The row is orange and says **INCOMPATIBLE VERSION**? See §9.5.

### Step 5 — Add three more phones

Repeat steps 2–4. Slots P2, P3, P4 fill. Each gets a different color, and every one of them shows
`ACTIVE SEAT`.

### Step 6 — Add phones 5 through 8

They connect exactly the same way, but their TV slots read **`SPECTATOR QUEUE`** instead of `ACTIVE SEAT`.

✅ **On those phones**, once a match starts, you should see:

```
      👥
   SPECTATING
   #1 IN QUEUE
Winner stays — you're in the queue
```

✅ A **9th** phone is rejected with **CAN'T JOIN** and
*"This PartyBox already has 8 controllers."*

### Step 7 — Open the game menu

Tap **OPEN GAME MENU** on any connected phone (or press Select on the remote / Return on the Mac).
Any connected player can drive the menus — the phone says so:
*"Anyone connected can move the party forward."*

✅ TV: **GAME SELECT** with one entry, **FOUR-WAY PONG**, subtitled
`1–4 players • Three lives • Winner stays`.
✅ Every phone switches to the menu layout: the game name plus **▲ ▼**, **SELECT**, **BACK**.

### Step 8 — Start the match

Tap **SELECT**.

✅ TV: the Pong arena, with a life counter (`◆◆◆`) along each occupied edge.
✅ Each of the four active phones becomes a **paddle track** in that player's color, labelled
`P<n> <name>`, with an orientation hint:

| Seat | Edge | Hint on the phone |
|---|---|---|
| 1st to join | bottom | `LEFT ← PADDLE → RIGHT` |
| 2nd | top | `LEFT ← PADDLE → RIGHT` |
| 3rd | left | `BOTTOM ← PADDLE → TOP` |
| 4th | right | `BOTTOM ← PADDLE → TOP` |

Drag anywhere on the track to move — you don't have to grab the paddle itself
(`DRAG ANYWHERE ON THE TRACK`).

### Step 9 — Play, and watch the diagnostics

While playing, check the top of each phone:

- The **host name** and `P<n> <name>` on the left.
- A **latency badge** on the right, e.g. `12 MS`. **Green under 50 ms, orange above.** On a healthy home
  network this should sit in the single digits to low tens. Orange during play means you have a Wi-Fi
  problem, not a code problem — see §9.7.

Haptics confirm the round trip is working end to end:

| Event | What the phone does |
|---|---|
| Your paddle hits the ball | Light tap |
| You lose a life | Heavy thud |
| You're eliminated | Error buzz |
| You win | Success double-tap |

Also note: **a running match can't be exited early.** There's no quit button by design. Let it finish.

### Step 10 — Game over and rotation

Last player standing wins.

✅ TV: **ROUND COMPLETE**, then `P<n> <NAME> WINS`, subtitle `Winner stays • Select for the next match`,
and the controls hint `SELECT: NEXT MATCH • MENU/ESC: GAME SELECT`.
✅ Phones: the same title with **NEXT MATCH** and **GAME MENU** buttons.

Press **NEXT MATCH** and watch the seats rotate: the winner keeps their seat, the other three go to the
back of the queue, and the next spectators in line are promoted into the free seats. This is the whole
point of the spectator queue — with 8 phones, everyone plays.

If only one player was in the match, you get **PRACTICE COMPLETE** with your rally count instead.

### Step 11 — Deliberately test reconnection

Worth doing once so you know what it looks like when it happens for real mid-party.

**Short interruption (under 15 seconds) — seat is held:**

1. Put one phone in **Airplane Mode** for ~5 seconds, then turn it off again.
2. ✅ TV: that player's card shows `RECONNECTING…` in orange, and the status line reads
   `Waiting 15 seconds for <name>…`.
3. ✅ Phone: **RECONNECTING**, then back to whatever layout it had — **same player number, same color,
   same seat**.

**Long interruption (over 15 seconds) — seat is lost:**

1. Airplane Mode for ~25 seconds.
2. ✅ TV: the slot empties and the status reads `<name> left the party`. If a match was running, that
   player forfeits (their lives drop to zero).
3. ✅ Phone: the client keeps retrying for 30 seconds, then gives up to **CONNECTION LOST** with a
   **BACK TO HOST PICKER** button.

**Host restart — everyone returns to the picker:**

1. Quit and relaunch the host app.
2. ✅ Phones do **not** silently rejoin a different session. Each host launch mints a new instance ID, so
   phones bounce back to **CHOOSE A HOST**, where the host reappears within a couple of seconds.

### Step 12 — Same-identity replacement

If the same person installs the app on a second device with a restored backup (same controller ID) and
joins, the first connection is kicked with:

> *"This controller was replaced by another connection using the same identity."*

That's expected behaviour, not a bug.

---

## 9. Network troubleshooting

Discovery is where this kind of app breaks. Work through these in order.

### 9.1 Prove the host is advertising at all

From any Mac on the same network:

```bash
dns-sd -B _partybox._tcp local.
```

You should see a line naming your host, e.g.:

```
Timestamp     A/R  Flags  if Domain  Service Type     Instance Name
12:04:31.882  Add      3   6 local.  _partybox._tcp.  Living-Room's PartyBox
```

- **Host listed** → advertising works; the problem is on the phone or between the phone and the host.
  Go to 9.3.
- **Nothing listed** → the host isn't advertising, or mDNS isn't crossing to your Mac. Go to 9.2.

To also see the address and port it resolves to:

```bash
dns-sd -L "Living-Room's PartyBox" _partybox._tcp local.
```

The TXT record shown there carries `v=2` (protocol version) and `id=<uuid>` (this host launch's instance).

### 9.2 Read the host's own log

The transport logs under the OSLog subsystem **`PartyNet`** (categories `HostTransport`,
`ClientTransport`, `PartyHost`).

**Mac host:**

```bash
log stream --predicate 'subsystem == "PartyNet"' --level debug
```

**Apple TV host:** open **Console.app** on your Mac, select the Apple TV in the sidebar (it must be
network-paired, per §5.2), and filter on `PartyNet`.

The line you're looking for, emitted right after the listeners bind:

```
PartyBox host ready on TCP 52408, UDP 52409
```

- **You see it** → the host is up and bound. Discovery is the problem, not startup.
- **You don't** → the host never started. The lobby status line will say
  `Could not start: <error>`. Usual causes: Local Network permission denied (§9.3), or the macOS
  firewall blocking incoming connections (§9.4).

Other useful debug-level lines when things go wrong mid-party: `Control connection ended: …`,
`UDP flow ended: …`, `Input acknowledgment failed: …`, `Client session ended: …`, `Broadcast failed: …`.

### 9.3 Local Network permission on the iPhone

This is the single most common cause of "it just doesn't find anything."

The app tells you when it detects it. Any error containing *denied* or *policy* is rewritten to:

> *"Local Network access is off. Enable it for PartyBox Controller in Settings, then try again."*

And after 4 seconds with no hosts found you get the generic card:

> *"Make sure the host is open on the same Wi‑Fi network. If asked, allow Local Network access. You can
> change that permission in Settings."*

Fix it:

1. **Settings ▸ PartyBox Controller ▸ Local Network** — toggle **on**.
   (The **OPEN SETTINGS** button on that card takes you straight there.)
2. Force-quit and relaunch the app.
3. If the toggle isn't there at all, iOS never recorded a decision. Reset privacy prompts with
   **Settings ▸ General ▸ Transfer or Reset iPhone ▸ Reset ▸ Reset Location & Privacy**, then relaunch
   the app and tap **Allow**.

Do the same check on the **host** side: tvOS **Settings ▸ Apps ▸ PartyBox ▸ Local Network**, macOS
**System Settings ▸ Privacy & Security ▸ Local Network**.

### 9.4 macOS firewall (Mac host only)

**System Settings ▸ Network ▸ Firewall**:

- If the firewall is on, open **Options…** and confirm `PartyBox` is listed as
  **Allow incoming connections**.
- Make sure **Block all incoming connections** is **off** — it silently kills the TCP listener regardless
  of per-app settings.
- If PartyBox isn't listed, delete any stale entry, rebuild, and relaunch so the alert fires again.

There are **no fixed ports to open** — the listeners take ephemeral ports every launch, so per-port
firewall rules are useless here. Allow the application, not a port.

### 9.5 Router and Wi-Fi configuration

If `dns-sd` finds nothing from a Mac that's on the same Wi-Fi as the host:

| Check | Why |
|---|---|
| **AP / client isolation off** | Isolation lets devices reach the internet but not each other. Kills PartyBox entirely. |
| **Not a guest network** | Guest SSIDs almost always enable isolation. Put everyone on the main SSID. |
| **Same subnet** | Host and phones must share one subnet. A separate IoT VLAN or a second router in NAT mode will break it. |
| **mDNS forwarded across bands** | Some mesh systems (and some "smart" band-steering) drop mDNS between 2.4 GHz and 5 GHz. Symptom: *"discovery works sometimes."* Force the phones and the host onto the same band to test. |
| **No VPN on the phone** | A VPN profile can capture the local subnet. Disable it and retry. |

`CANDIDATE STACK.md` puts it this way:

> **Router config:** you control the AP, so just confirm client isolation is off and mDNS isn't being
> dropped across bands — some consumer mesh gear does this by default and it presents as
> "discovery works sometimes."

Remember there is **no AWDL/peer-to-peer fallback** — `peerToPeerIncluded(false)` is set on every listener,
browser and connection. If mDNS over the infrastructure network doesn't work, nothing works.

### 9.6 "INCOMPATIBLE VERSION" in the host list

The host row is orange, disabled, and labelled `INCOMPATIBLE VERSION`. The Bonjour TXT record's `v` field
doesn't match `PartyNetConstants.protocolVersion` (currently `2`).

Cause: the phone and the host were built from different commits. Rebuild **both** apps from the same
checkout and reinstall. If you're on TestFlight, ship a new controller build alongside your host update.

### 9.7 Play is laggy or the latency badge is orange

The badge on each phone shows measured round-trip time; it turns orange at **50 ms**.

What's happening under the hood, so you know what to blame:

- Input goes over **UDP at 60 Hz**. If the host stops acknowledging UDP for **1 second**, the phone
  silently falls back to sending input over **TCP at ~30 Hz** and keeps playing. It feels heavier but it
  doesn't disconnect.
- The control channel pings every **2 seconds** and gives up after **6 seconds** without a reply.

Things that actually help, in order of effect:

1. **Put the host on Ethernet.** Biggest single win — it takes the host out of Wi-Fi contention.
2. Move everyone to **5 GHz** and off any congested 2.4 GHz channel.
3. Get the phones physically closer to the AP; eight phones all transmitting at 60 Hz is real airtime.
4. Kick anything doing a big download off the network for the duration.

### 9.8 Last-resort escape hatch: connect by address

If Bonjour is broken on the venue's network and you can't fix it, a **Debug** build of the controller can
bypass discovery entirely:

1. Get the host's IP and TCP port from the log line in §9.2
   (`PartyBox host ready on TCP 52408, …`).
2. Run the controller from Xcode with a launch argument
   (**Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments**):

   ```
   --host 192.168.1.42:52408
   ```

   IPv6 works too, bracketed, with an optional scope: `--host [fe80::1%en0]:52408`.
3. The picker gains an extra row named **UI Test Host**. Tap it to connect directly.

Caveats: this is compiled out of Release builds, the port changes every time the host restarts, and it
only helps for phones you can run from Xcode. It's a debugging tool, not a party feature.

### 9.9 Security reminder

The control channel is **plain JSON over TCP with no TLS**, and there is **no join code or pairing
secret**. Any device on the LAN running the controller app can join your party and take a seat. That's
fine on your home network; don't do it on a shared or public one.

---

## 10. Reference

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
| `--ui-testing` | Marks a UI-test run |

Controller (`PartyBox Controller`):

| Argument | Effect |
|---|---|
| `--host <HOST:PORT>` | Add a direct-address row to the picker, bypassing Bonjour (see §9.8) |
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
| `Local Network access is off…` | Phone, discovery card | See §9.3 |
| `The host address is invalid.` | Phone | Bad `--host` argument (§9.8) |

---

## 11. See also

- [`CANDIDATE STACK.md`](CANDIDATE%20STACK.md) — the chosen architecture and the network-reliability advice
  quoted above.
- [`CHECKLIST.md`](CHECKLIST.md) — the landscape survey behind the transport choice (Network.framework +
  Bonjour over MultipeerConnectivity).
- [`REFERENCES.md`](REFERENCES.md) — prior-art survey on pairing, identity, and reconnection.
- `scripts/verify.sh [normal|asan|tsan|soak|all]` — the automated build/test/soak suite. It needs
  `jq`, `plutil`, `swift`, `xcodebuild`, `xcrun` (and optionally `xcbeautify`), creates and tears down
  throwaway simulators, and writes artifacts to `.verification/<timestamp>/`. Not needed to play, but it's
  the fastest way to confirm a checkout is healthy.
