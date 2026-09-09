# macOS UI-test activation failures

## Scope

`scripts/verify.sh normal` currently reaches the macOS host UI tests after the
PartyNet tests and host unit tests pass, but XCTest does not consistently obtain
an active PartyBox window. This is a test-launch problem: it is distinct from a
compile failure, a unit-test failure, and the controller's PartyFault live smoke
test.

Two signatures have been observed:

1. `XCUIApplication.activate()` reports PartyBox as `Running Background` rather
   than `Running Foreground`.
2. The process launches and exposes the application menu bar, but its accessibility
   hierarchy contains no main window or fixture elements such as
   `host.phase.lobby`.

The same background-activation signature appears in verification artifacts from
before the current transport, bot, identity, and UI changes, including:

- `.verification/20260908T211054Z/macos-normal.log`
- `.verification/acceptance-20260908T1904Z/macos-normal.log`
- `.verification/final-all-20260908T2024Z/macos-normal.log`

Recent reproductions are stored in:

- `.verification/20260908T215353Z/macos-normal.xcresult`
- `.verification/20260908T215830Z/macos-normal.xcresult`

These `.verification` artifacts are local and intentionally ignored by Git.

## Likely causes

Investigate these in roughly this order:

1. **Window restoration and SwiftUI scene state.** PartyBox uses a SwiftUI window
   scene. A test launch may restore a process or scene without creating or showing
   its main window, which matches the menu-bar-only accessibility hierarchy.
2. **Terminate/relaunch race.** The UI tests repeatedly terminate and relaunch the
   same application. XCTest may start the next scenario while the previous process,
   scene, or accessibility registration is still shutting down.
3. **Xcode or macOS beta regression.** The failures occur on the current beta toolchain
   and macOS runtime. LaunchServices, XCTest, or SwiftUI scene activation may be
   mishandling a macOS app that is repeatedly launched by UI tests.
4. **Stale LaunchServices or DerivedData state.** A stale registration, cached test
   runner, restored application state, or mismatched built product can make XCTest
   address a process that is alive but does not own the expected window.
5. **Desktop-session activation denial.** Another app, a locked/headless session, or
   macOS focus policy can prevent XCTest from promoting the process to foreground.
6. **Main-actor startup stall.** A synchronous startup task could delay window
   creation. This is less likely because the process remains responsive enough to
   publish a menu bar, and expensive audio sample generation has been moved off the
   main actor, but signposts should confirm the timing.

The first two causes best explain both observed signatures. Do not assume the
failure is fixed merely because one retry succeeds.

## Reproduction

Run the normal profile and retain its timestamped artifacts:

```bash
scripts/verify.sh normal
```

For a quicker host-only reproduction, use the macOS test plan:

```bash
xcodebuild \
  -collect-test-diagnostics never \
  -project PartyBox.xcodeproj \
  -scheme PartyBox \
  -testPlan PartyBox-Normal \
  -destination 'platform=macOS' \
  -resultBundlePath .verification/activation-repro.xcresult \
  test
```

Before comparing runs, record the Xcode build, macOS build, destination, whether the
desktop was unlocked, and whether a PartyBox process was already running. Preserve
the result bundle even if the text log looks sufficient; its process and
accessibility diagnostics are the stronger evidence.

## Investigation plan

1. Add startup signposts for application initialization, scene creation, first
   window attachment, first root-view appearance, and fixture selection. Export
   those signposts with failed result bundles.
2. In UI-test setup, terminate any existing `XCUIApplication`, wait until its state
   is `.notRunning`, then launch. After launch, wait for `.runningForeground` and
   fail with the current application state plus an accessibility snapshot if it
   never arrives.
3. Give every scenario an isolated restoration/defaults namespace. For UI-testing
   launches, disable normal window restoration or explicitly discard stale scene
   state before constructing the fixture window.
4. Add a UI-testing-only activation fallback that creates and orders front the main
   window when the app becomes active. Keep it narrowly gated by `--ui-testing` so
   production window behavior is unchanged.
5. Split fixture tests so a failed launch reports one scenario, process ID, and
   application state instead of obscuring the first failure inside a loop.
6. Reproduce with a clean DerivedData directory and reset LaunchServices state,
   then compare with the ordinary incremental run. Do not make destructive cleanup
   the default harness behavior unless it proves necessary.
7. Run the same test plan on a stable Xcode/macOS pair. If it passes there and fails
   on the beta pair, reduce the app to a minimal SwiftUI `WindowGroup` reproduction
   before filing a toolchain issue.
8. Once the launch is stable, add bounded retry only around the known activation
   transition. A retry should create a fresh process and capture the first failure;
   it must not turn arbitrary assertion failures into passes.

## Proposed launch helper contract

Centralize host UI-test startup in one helper with this behavior:

- terminate and wait for `.notRunning`;
- set a unique defaults/restoration suite for the scenario;
- launch once and wait for `.runningForeground`;
- wait for a generic `host.app.ready` accessibility marker before looking for the
  scenario-specific marker;
- on failure, attach `debugDescription`, a screenshot, application state, process
  information, and startup signposts;
- permit at most one fresh-process retry for activation/window absence only.

This makes an activation failure distinguishable from a fixture-rendering failure.
The generic ready marker should be attached only after the main window and root view
are present, not merely when `App.init` completes.

## Acceptance criteria

- Twenty consecutive host UI-test launches succeed from a clean checkout and
  twenty succeed from an incremental checkout.
- Every scenario starts with exactly one foreground PartyBox process and at least
  one visible main window.
- Killing a previous launch immediately before a test does not orphan the next
  launch in `Running Background`.
- A deliberately missing fixture still fails as a fixture assertion and is not
  hidden by activation retry logic.
- Stable and beta toolchains either both pass or have a documented, minimized
  toolchain-specific failure.
- `scripts/verify.sh normal` completes the macOS host UI tests and proceeds to the
  tvOS, iOS, and Release checks without manual focus or process cleanup.

## Related but separate: controller PartyFault smoke test

`testLiveConnectionThroughPartyFault` requires a running `partyfault` process and a
non-empty `PARTYFAULT_HOST`. `scripts/verify.sh normal` supplies both. A direct
controller `xcodebuild test` invocation without that setup is not a valid live-smoke
run; fixture and interaction tests can still pass while this one fails to connect.
Future standalone commands should either start PartyFault and pass its address or
explicitly skip this smoke test.
