# PartyBox Manual QA

This runbook covers hands-on validation of PartyBox on a physical Apple TV with one or more physical
iPhones running PartyPad. It complements the automated suites in `scripts/verify.sh`; it focuses on
hardware, local-network discovery, permissions, lifecycle events, presentation on a television, and
multi-device behavior that simulators cannot reproduce faithfully.

## Goals

- Prove that a fresh Apple TV and iPhone can discover, join, play, disconnect, and recover on a real LAN.
- Exercise every game with real touch, motion, haptic, remote, audio, and television output.
- Verify the eight-controller limit, player identity, captain behavior, Party Cup progression, and history.
- Capture enough evidence to reproduce failures without recording player names or network addresses in
  shared bug reports.

## Test record

Copy this table into the test report before each session.

| Field | Value |
|---|---|
| Date and tester | |
| Git commit | |
| Configuration | Debug / Release |
| Xcode version | |
| Apple TV model, name, and tvOS | |
| Apple TV connection | Ethernet / Wi-Fi, band if known |
| iPhone models and iOS versions | |
| PartyBox build/version | |
| PartyPad build/version | |
| Router or access point | |
| Network notes | Main/guest SSID, VPN, mesh, VLAN, unusual settings |

Useful build-record commands:

```bash
git rev-parse --short HEAD
xcodebuild -version
xcrun devicectl list devices
```

## Required equipment

Minimum smoke-test setup:

- One Apple TV running tvOS 26 or later.
- One iPhone running iOS 26 or later.
- One Mac running Xcode 26.3 or later and signed into the development team.
- A LAN shared by the Mac, Apple TV, and iPhone, with client isolation disabled.

Recommended regression setup:

- Four iPhones for the classic Four-Way Pong arena.
- Eight iPhones for full-room coverage.
- A ninth iPhone for capacity rejection.
- Both Ethernet and Wi-Fi availability for the Apple TV.
- At least two iPhone models or screen sizes.

## Preconditions

1. Build both apps from the same commit. Do not mix an old TestFlight controller with a newer host.
2. Pair the Apple TV with Xcode and enable Developer Mode on the Apple TV.
3. Select the `PartyBox` scheme and the physical Apple TV destination, then build and run.
4. Install PartyPad from the `PartyBox Controller` scheme or TestFlight on each iPhone.
5. Confirm that all devices are on the same real LAN. PartyBox deliberately does not use AWDL as a
   fallback.
6. Unless a test says otherwise, start with Local Network access enabled for both apps, no VPN on the
   phones, and no debug `--scenario` argument.
7. Confirm that the TV lobby says `Ready for controllers` before starting controller tests.

For a release-candidate pass, use a Release host and the exact controller build intended for testers.
Use Debug builds for diagnostics, deterministic seeds, bots, or direct-address testing.

## Evidence and diagnostics

For every failure, record:

- Test ID and exact step.
- Expected and actual behavior.
- The host and controller build identifiers.
- Device and OS versions.
- Whether the Apple TV was on Ethernet or Wi-Fi.
- A screenshot or short recording when the problem is visual.
- Relevant Xcode or Console logs with timestamps.
- Whether the issue reproduces after a clean app relaunch.

The host transport logs under the OSLog subsystem `PartyNet`. With Xcode attached, use the debug
console. Otherwise, select the paired Apple TV in Console.app and filter for `PartyNet`.

From a Mac on the same LAN, verify Bonjour independently with:

```bash
dns-sd -B _partybox._tcp local.
```

For a paired device, `xcrun devicectl device capture screenshot` can save the Apple TV display as a PNG.
Use a filename containing the test ID and timestamp. Redact personal names, IP addresses, and device
identifiers before sharing evidence outside the test team.

## Fifteen-minute smoke pass

Stop and file a blocker if any step fails.

| ID | Action | Expected result |
|---|---|---|
| SMOKE-01 | Cold-launch PartyBox on the Apple TV. | The lobby appears with eight open slots and `Ready for controllers`. No layout is clipped at the television edges. |
| SMOKE-02 | Cold-launch PartyPad on one iPhone and allow Local Network access if asked. | The Apple TV host appears within four seconds as `READY TO JOIN`. |
| SMOKE-03 | Set a player name, save it, and join the host. | PartyPad reaches `YOU'RE IN`; TV slot P1 shows the same name and an active seat. |
| SMOKE-04 | Open the game menu from the captain phone. | The TV shows five games, Party Cup, and History & Leaderboard. The phone changes to menu controls. |
| SMOKE-05 | Start Signal Snap and complete one round with touch controls. | Input is responsive, score/state agree on TV and phone, and the latency badge remains green under normal LAN conditions. |
| SMOKE-06 | Send the phone to the background for about five seconds, then return. | The TV briefly shows `RECONNECTING…`; the phone returns to the same player number, color, and layout. |
| SMOKE-07 | Finish the match and choose the game menu. | Results are correct, controls still work, and the game menu returns without restarting either app. |
| SMOKE-08 | Quit and relaunch PartyBox. | PartyPad returns to the host picker instead of silently joining the new host session. The relaunched host reappears. |

## Full regression

### Host installation and lobby

- [ ] **HOST-01 — First installation:** Install PartyBox from Xcode onto an Apple TV that does not have
  the current build. The build signs, installs, and launches without manual file transfer.
- [ ] **HOST-02 — Local Network allowed:** On first launch, allow Local Network access. The lobby reaches
  `Ready for controllers`, and `_partybox._tcp` is visible with `dns-sd`.
- [ ] **HOST-03 — Cold launch:** Force-quit and relaunch the app. The lobby appears without stale players,
  stale scores, or a stale connection warning.
- [ ] **HOST-04 — Host name:** Confirm the advertised row on PartyPad matches the TV badge. Renaming the
  Apple TV and relaunching PartyBox should produce a correspondingly updated host name.
- [ ] **HOST-05 — Remote focus:** Using only the Siri Remote, traverse every item in the game menu,
  Party Cup picker, history screen, results screen, and any settings shown on the host. Focus must remain
  visible and must not become trapped.
- [ ] **HOST-06 — Remote actions:** Verify direction, Select, and Menu/Back. A single physical action must
  not cause duplicate navigation or skip multiple items.
- [ ] **HOST-07 — Television safe area:** Inspect all screens at the television's normal picture mode.
  Text, focus rings, scores, lives, and controls must remain inside the visible area.
- [ ] **HOST-08 — Sleep and wake:** Put the Apple TV to sleep with the app active, wake it, and return to
  PartyBox. The app must either recover the session clearly or return to a usable lobby; it must not hang.
- [ ] **HOST-09 — Relaunch after update:** Install a newer build over the existing app. It launches, can
  host a session, and retains only data designed to persist.

### Discovery and permissions

- [ ] **DISC-01 — Normal discovery:** With both devices on the same LAN, the host appears on PartyPad
  within four seconds and is enabled as `READY TO JOIN`.
- [ ] **DISC-02 — Multiple hosts:** If a second PartyBox host is available, both appear as distinct rows,
  and selecting one never connects to the other.
- [ ] **DISC-03 — Host starts late:** Open PartyPad first, then launch PartyBox. The host appears without
  force-quitting PartyPad.
- [ ] **DISC-04 — Host stops:** While the picker is visible, quit PartyBox. Its row disappears or becomes
  unavailable promptly without leaving an indefinitely joinable stale entry.
- [ ] **DISC-05 — Controller permission denied:** On a clean install or reset test device, deny PartyPad's
  Local Network prompt. Confirm the actionable denial/no-host UI and `OPEN SETTINGS` path. Re-enable the
  permission, relaunch, and verify discovery recovers.
- [ ] **DISC-06 — Host permission denied:** Deny PartyBox's Local Network permission on a resettable test
  Apple TV. Confirm the host reports a useful startup failure rather than pretending to be ready. Restore
  permission and verify recovery after relaunch.
- [ ] **DISC-07 — Incompatible protocol:** Run intentionally mismatched debug builds. The controller row
  is orange, disabled, and labelled `INCOMPATIBLE VERSION`; it must not attempt a partial connection.
- [ ] **DISC-08 — Guest or isolated network:** On a controlled test network, enable client isolation or
  place one device on a guest SSID. Discovery should fail cleanly and recover when both return to the same
  non-isolated LAN.
- [ ] **DISC-09 — Ethernet/Wi-Fi bridge:** Put the Apple TV on Ethernet and the phone on Wi-Fi. Discovery,
  join, and play must work when both sides are on the same routed subnet.
- [ ] **DISC-10 — VPN:** Enable a phone VPN that captures LAN traffic, observe clean failure, then disable
  it. PartyPad should discover the host again without reinstalling either app.

### Joining, roster, and identity

- [ ] **JOIN-01 — First player:** The first phone receives P1, a unique color/mark, and the captain crown.
  The TV and every connected phone show the same roster.
- [ ] **JOIN-02 — Rename before joining:** Save a new name in the picker and join. The TV displays the
  saved name exactly as PartyPad displays it.
- [ ] **JOIN-03 — Rename while connected:** Change the name while connected. The host and other phones
  update without changing the player's number, color, or captain role.
- [ ] **JOIN-04 — Sequential joins:** Join phones two through eight. Seat numbers follow join order, and
  colors/marks remain distinguishable.
- [ ] **JOIN-05 — Full-room rejection:** Attempt to join a ninth phone. It receives `CAN'T JOIN` and
  `This PartyBox already has 8 controllers.` Existing players remain unaffected.
- [ ] **JOIN-06 — Player leaves lobby:** Disconnect one phone long enough to exceed the 15-second grace
  period. Its slot becomes open, and a new controller can occupy the available seat.
- [ ] **JOIN-07 — Captain leaves:** Disconnect the captain beyond the grace period. Verify that the room
  remains operable and captain ownership is reassigned or otherwise handled consistently.
- [ ] **JOIN-08 — Persistent identity:** Force-quit and relaunch PartyPad, then reconnect within the host's
  grace period. It returns to the same seat and color.
- [ ] **JOIN-09 — Same-identity replacement:** Launch a second debug controller with the same explicit
  controller UUID. The newer connection replaces the old one, and the old phone sees the documented
  replacement message.
- [ ] **JOIN-10 — Saved name:** Relaunch PartyPad after ending the session. The previously saved display
  name remains populated.

### Shared navigation and ready checks

- [ ] **NAV-01 — Captain opens menu:** Only the captain gets shared navigation authority. Opening the
  menu updates the TV and every phone to the matching layout.
- [ ] **NAV-02 — Phone navigation:** Navigate through every menu entry using PartyPad's direction,
  Select, and Back controls. The host moves once per press and preserves visible focus.
- [ ] **NAV-03 — Non-captain input:** A non-captain phone readies up where appropriate and cannot
  unexpectedly hijack shared menu navigation.
- [ ] **NAV-04 — Mixed input sources:** Alternate Siri Remote and captain-phone navigation. Focus and
  selection remain synchronized without double activation.
- [ ] **NAV-05 — Ready cancellation:** Toggle ready state, back out, and re-enter where the UI permits.
  The room does not start until the required ready conditions are satisfied.
- [ ] **NAV-06 — Rapid input:** Send quick direction and Select presses from the remote and phone. The UI
  remains deterministic and does not select an unintended game.

### Game coverage

Run every row first with touch controls. Repeat the applicable motion rows after enabling and calibrating
motion in PartyPad settings.

| ID | Game and setup | Checks |
|---|---|---|
| GAME-01 | Four-Way Pong, one player | A practice match starts; bottom paddle follows touch; rally count increments; result is `PRACTICE COMPLETE`. |
| GAME-02 | Four-Way Pong, two to four players | Join order maps to bottom, top, left, and right. Every paddle follows its own phone. Lives start at three, decrement correctly, and elimination/winner results agree everywhere. |
| GAME-03 | Four-Way Pong, five to eight players | Every phone enters the horizontal GATE qualifier. Exactly the expected top four advance to the classic arena, with identity and scores preserved. |
| GAME-04 | Signal Snap | Each direction produces the matching semantic input. Correct and incorrect responses score consistently; simultaneous answers resolve deterministically. |
| GAME-05 | Gravity Grab | The two-dimensional drag surface covers the intended range without jumps or dead zones. Optional calibrated motion provides stable neutral and usable full-range steering. |
| GAME-06 | Snake Pit | Direction input turns reliably; collisions and three lives are consistent on TV and phones; eliminated players cannot continue affecting play. |
| GAME-07 | Last Light | Touch or motion movement is responsive; red hazards and elimination are synchronized; the final winner is correct. |
| GAME-08 | Results and rematch | `NEXT MATCH` starts a clean rematch with the same roster. Scores, lives, and temporary effects do not leak from the prior round. |
| GAME-09 | Results and menu | `GAME MENU` returns all devices to the menu. No phone remains stuck in the previous control layout. |
| GAME-10 | No early exit | During a running match, verify the intentional lack of a quit action. Back/Menu input must not leave some devices in a different state. |

### Party Cup, history, and persistence

- [ ] **CUP-01 — Event selection:** The captain can select three distinct events. Duplicate selection is
  prevented or clearly rejected.
- [ ] **CUP-02 — Cup start:** The chosen events appear in the intended order, and all players receive the
  correct first-game controls after the ready check.
- [ ] **CUP-03 — Standings:** Finish each event and compare awarded placement points with the standings.
  Ties, if encountered, are shown consistently on every device.
- [ ] **CUP-04 — Progression:** Advancing from standings starts the next selected event, not a stale or
  already-completed event.
- [ ] **CUP-05 — Cup completion:** The final winner and trophy are correct. The room can return to the
  menu and start another Free Play or Cup session.
- [ ] **CUP-06 — History:** Open History & Leaderboard and verify the completed session appears with the
  correct winner and results.
- [ ] **CUP-07 — Relaunch persistence:** Relaunch the apps and confirm trophies/history intended to
  persist remain correct, while transient lobby and match state do not reappear as active.
- [ ] **CUP-08 — Controller history export:** From My History, prepare redacted diagnostics. Inspect the
  exported JSON and confirm it contains useful state/counters but no player names, controller IDs, IP
  addresses, or input payloads.

### Controller input, motion, haptics, and presentation

- [ ] **CTRL-01 — Portrait layout:** Check all PartyPad screens on each test iPhone. Controls are fully
  visible in portrait with no overlap, clipping, or accidental home-indicator conflict.
- [ ] **CTRL-02 — Touch edges:** Drag from the center to every edge and corner of each analog/track
  control. Values reach their intended extremes smoothly and return to neutral as designed.
- [ ] **CTRL-03 — Multi-touch and interruption:** Add an extra finger, receive a notification, or brush
  the screen edge during play. Input must not become stuck after the interruption ends.
- [ ] **CTRL-04 — Motion calibration:** Enable motion, hold the phone in the instructed neutral pose, and
  calibrate. Neutral remains stable and full-range input is achievable without extreme movement.
- [ ] **CTRL-05 — Motion recalibration:** Rotate posture, recalibrate, and verify the new neutral takes
  effect immediately without changing player identity or connection state.
- [ ] **CTRL-06 — Effects enabled:** Confirm light hit, heavy life-loss, elimination error, and win
  success haptics on supported hardware. Brief result-color washes match the event.
- [ ] **CTRL-07 — Effects disabled:** Disable effects in the gear menu. Haptics and color washes stop,
  while gameplay input and state updates continue.
- [ ] **CTRL-08 — Latency badge:** Confirm the badge is readable, reports plausible round-trip time, and
  changes from green to orange at 50 ms or above under controlled impairment.
- [ ] **CTRL-09 — Accessibility settings:** Check larger text, Bold Text, Increase Contrast, Reduce
  Motion, and VoiceOver on at least one iPhone. Critical actions must remain discoverable and usable.

### Reconnection and lifecycle

- [ ] **LIFE-01 — Short Airplane Mode:** Enable Airplane Mode for about five seconds, then restore Wi-Fi.
  The TV shows `RECONNECTING…` and `Waiting 15 seconds for <name>…`; the phone returns to the same seat,
  color, and active layout.
- [ ] **LIFE-02 — Long Airplane Mode:** Keep Airplane Mode enabled for about 25 seconds. The host releases
  the seat after 15 seconds. If a match is active, the player forfeits. The phone eventually reaches
  `CONNECTION LOST` and offers `BACK TO HOST PICKER`.
- [ ] **LIFE-03 — Lock and unlock phone:** Lock a connected iPhone for five seconds, then unlock. It
  reconnects within the grace window and no input remains stuck.
- [ ] **LIFE-04 — Background and foreground:** Background PartyPad briefly and return. It restores the
  current control layout instead of returning to an unrelated screen.
- [ ] **LIFE-05 — Force-quit controller:** Force-quit PartyPad during the lobby and during a match. The host
  shows reconnect grace, then releases/forfeits the player if the app does not return.
- [ ] **LIFE-06 — Host force-quit:** Force-quit PartyBox with controllers connected. Every phone leaves the
  active layout and reaches a clear lost-host or picker state.
- [ ] **LIFE-07 — Host relaunch:** Relaunch PartyBox after LIFE-06. Its new session appears in the picker;
  phones do not silently attach to it because the host instance ID changed.
- [ ] **LIFE-08 — Wi-Fi roam:** If the test network has multiple access points, walk a phone between them
  during play. A brief roam should recover without identity loss.
- [ ] **LIFE-09 — Network change:** Move a phone to another SSID or cellular, then back to the LAN. Failure
  and recovery are clear; the app does not remain forever in `CONNECTING`.
- [ ] **LIFE-10 — Repeated cycles:** Repeat short disconnect/reconnect ten times. No duplicate roster
  entries, leaked seats, increasing latency, or eventual crash occurs.

### Capacity, concurrency, and endurance

- [ ] **LOAD-01 — Four controllers:** Keep four phones connected for 15 minutes while playing multiple
  games. All inputs remain responsive and no controller changes seats.
- [ ] **LOAD-02 — Eight controllers:** Join the full room and play at least Signal Snap, Gravity Grab,
  Snake Pit, Last Light, and Pong's qualifier. Monitor latency badges and the host log.
- [ ] **LOAD-03 — Simultaneous join:** Have several phones tap the host row at nearly the same time. Each
  receives one unique seat; no duplicate slot or captain appears.
- [ ] **LOAD-04 — Simultaneous input:** With all controllers connected, continuously manipulate controls
  for at least two minutes. The host stays responsive and every player's state continues changing.
- [ ] **LOAD-05 — Join/leave churn:** Repeatedly disconnect and replace players while the room is idle.
  Open seats are reused correctly, and existing players retain identity.
- [ ] **LOAD-06 — One-hour session:** Run mixed Free Play and Party Cup for at least one hour. Record any
  crash, hang, memory warning, audio loss, frame-rate drop, or latency trend.
- [ ] **LOAD-07 — Overnight idle:** Leave the lobby running overnight where practical. In the morning,
  discovery and a fresh join still work without relaunching the host.

### Network degradation

Perform these only on a controlled test network or through the repository's PartyFault tooling. Do not
degrade a shared production network.

- [ ] **NET-01 — Elevated latency:** Add delay until the phone badge crosses 50 ms. It turns orange, but
  gameplay remains coherent and the control connection stays alive within timeout limits.
- [ ] **NET-02 — UDP loss:** Drop or interrupt UDP acknowledgements for more than one second while keeping
  TCP alive. Input continues through the approximately 30 Hz TCP fallback instead of disconnecting.
- [ ] **NET-03 — UDP recovery:** Restore UDP. Confirm that input remains current and no old buffered input
  replays out of order.
- [ ] **NET-04 — Brief total outage:** Interrupt both channels for less than 15 seconds. The controller
  reconnects to its held seat.
- [ ] **NET-05 — Extended total outage:** Interrupt both channels beyond the grace and retry windows. Both
  sides end in the documented released-seat/lost-connection state.
- [ ] **NET-06 — Congested Wi-Fi:** Generate ordinary LAN traffic while playing with several phones.
  Record p50/p95 observed latency, visible stutter, and whether Ethernet on the host improves the result.

### Audio, video, and television presentation

- [ ] **AV-01 — 4K output:** Inspect the lobby, menus, every game, standings, and results at the Apple TV's
  normal 4K output. Geometry and text remain sharp and correctly proportioned.
- [ ] **AV-02 — 1080p output:** Repeat representative screens at 1080p. Nothing clips or becomes too small
  to read from normal seating distance.
- [ ] **AV-03 — Light/dark television conditions:** Check readability in both a bright room and a dark
  room. Player colors, focus, hazards, and secondary text retain sufficient contrast.
- [ ] **AV-04 — Audio route:** Verify arcade sounds through the actual HDMI receiver/television. Sound is
  synchronized, does not clip, and resumes after Apple TV sleep/wake or an HDMI route change.
- [ ] **AV-05 — Effects disabled:** Launch a Debug host with `--disable-effects`. Gameplay continues with
  no arcade audio and no audio-related errors.
- [ ] **AV-06 — Animation reduction:** Check normal animations and a Debug launch with
  `--disable-animations`. Both paths remain navigable and end in the same state.

## Optional debug fixtures

Debug-only launch arguments speed up focused UI checks but do not replace the real network pass.

Host examples:

```text
--host-name "QA PartyBox"
--bot-count 4
--seed 12345
--disable-animations
--disable-effects
```

Static host fixtures disable networking and include `empty-lobby`, `menu`, `four-way-match`, and
`game-over` through `--scenario <name>`. Controller fixtures include `empty-picker`,
`populated-picker`, `connecting`, `menu`, `paddle-bottom`, `paddle-top`, `paddle-left`, `paddle-right`,
`spectator`, `game-over`, `reconnecting`, `full-rejection`, `version-rejection`,
`local-network-denial`, and `connection-loss`.

Use `--bot-count 4 --host-name "QA PartyBox" --seed 12345` for a quick deterministic host exercise.
Remove every debug argument before release-candidate testing.

## Pass criteria

A release candidate passes manual QA when:

- Every smoke test passes on a physical Apple TV and physical iPhone.
- Every applicable full-regression test passes, or has a documented product-approved exception.
- All five games complete with correct results using real controller input.
- A short disconnect restores the same identity, while a long disconnect releases the seat cleanly.
- Local Network denial and restoration are understandable on both host and controller.
- Four-controller testing has no seat corruption or input crossover.
- Eight-controller testing has no crash, hang, or permanent connection loss on the target party network.
- No open critical or high-severity issue blocks installation, discovery, joining, input, results, or
  recovery.

## Defect template

```markdown
### [TEST-ID] Short title

- Commit/build:
- Apple TV model and tvOS:
- iPhone model and iOS:
- Apple TV connection: Ethernet / Wi-Fi
- Network:
- Reproduction rate:

Steps:
1.
2.
3.

Expected:

Actual:

Evidence:
- Screenshot/recording:
- Host log timestamp:
- Controller diagnostics:

Recovery/workaround:
```

## Related documentation

- [`../QUICKSTART.md`](../QUICKSTART.md) — installation, signing, distribution, and network troubleshooting.
- [`../README.md`](../README.md) — architecture and project layout.
- [`../PartyFault/README.md`](../PartyFault/README.md) — controlled network impairment tooling.
- `scripts/verify.sh [normal|asan|tsan|soak|all]` — automated verification profiles.
