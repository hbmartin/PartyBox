# TestFlight releases

Release from a Mac with Xcode 26.3 or newer, the iOS and tvOS SDKs installed, and
the release account signed in under **Xcode → Settings → Accounts**. The account
must be allowed to sign and upload builds for the Apple Developer team.

## One-time setup

1. In App Store Connect, create a **PartyBox** record with macOS and tvOS under
   the shared host bundle ID. Create a separate iOS record for **PartyPad**.
   Match the bundle IDs in the Xcode project to those records. The repository
   uses `me.haroldmartin.PartyBox` and `me.haroldmartin.PartyBox-Controller`.
   [Add a new app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
2. Install the build tool **sentry-cli**. Create one Sentry project for both apps.
   Copy its public HTTPS DSN, organization slug, and project slug. Create a Sentry
   organization token that can upload debug information to that project.
   Enable **Prevent Storing of IP Addresses** in the project settings.
   [Install sentry-cli](https://docs.sentry.io/cli/installation/)
   · [Configure Sentry’s data scrubbing](https://docs.sentry.io/platforms/apple/data-management/sensitive-data/)
3. Set `APPLE_TEAM_ID`, `SENTRY_DSN`, `SENTRY_ORG`, and `SENTRY_PROJECT` in the release shell.
   Load `SENTRY_AUTH_TOKEN` from your secret manager into the environment.
   The apps embed the public DSN. The token goes to sentry-cli only.

## Build and upload

Choose a positive build number higher than the last upload for every selected
platform. The marketing version comes from the Xcode project.

```bash
scripts/distribute.sh --build-number 42
scripts/distribute.sh --build-number 43 --platform ios
```

The default builds iPhone, Apple TV, and Mac. The script checks the platform,
build number, embedded DSN, Sentry environment, and binary-to-dSYM UUIDs when
building or resuming. On resume, a legacy archive with a missing environment key
produces a warning. An explicit environment must be `testflight`. The script
also checks app bundle permissions on Mac archives awaiting upload. If that
check fails, rebuild the archive. The script waits for Sentry to process the
symbols before uploading to Apple.

For signed archives alone, use `--archive-only`. This mode requires `APPLE_TEAM_ID`
and `SENTRY_DSN`. Xcode can contact Apple for provisioning. The script prints the
release directory under `.distribution/` with the archives, logs, and any upload
receipts.

```bash
scripts/distribute.sh --build-number 42 --archive-only
scripts/distribute.sh --resume .distribution/build-42.ABCDEF12
```

After Apple processes the builds, check TestFlight in both app records. Complete
any export compliance questions and assign the builds to your tester groups.
App Store Connect can deliver builds automatically to configured internal groups.
External groups may require Beta App Review.
[Apple’s TestFlight guide](https://developer.apple.com/testflight/)

## Recover an upload

- If a release directory is in use, use `lsof "<release-dir>/.lock"` to identify
  the holder. Wait for the previous distribution script and its Apple export to
  stop. Leave the regular lock file in place. If resume
  reports a legacy lock directory, verify that the previous script and its upload
  processes have stopped, then remove the empty directory with `rmdir "<release-dir>/.lock"`
  and keep all upload receipts. Then follow the upload status checks below.
- If archiving or archive validation failed on a fresh run, check `archive.log`,
  fix the issue, and run again with the same build number. The script writes
  `archives-ready` and allows uploads only after all selected archives pass validation.
- If a pending Mac archive fails the permission check on resume and the release
  directory has `archives-ready`, resume the valid iOS and tvOS archives separately
  with `--resume <release-dir> --platform ios` and `--resume <release-dir> --platform tvos`.
  Rebuild only the Mac archive with
  `scripts/distribute.sh --build-number N --platform macos`, using the original
  build number and keeping the receipts in the original release directory.
- If symbol upload failed, check `sentry.log`, fix the error, and resume from the
  printed release directory. Sentry skips debug files it already has.
- If an Apple upload failed or was interrupted, check `apple.log` and the
  **Build Uploads** status in App Store Connect for that platform, version, and
  build number. Resume each remaining platform with `--platform ios`, `--platform tvos`,
  or `--platform macos`. If Apple confirms a failed delivery,
  add `--retry-apple-upload` when resuming that platform. If Apple received it,
  wait for processing or inspect Apple’s delivery errors before reusing the
  build number. The script skips platforms with local upload receipts.
  [Check build upload status](https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata)

## Verify crash reporting

Sentry starts in Release builds with a configured DSN. Native crash reports
include diagnostic data such as stack traces, OS and app versions, and device
model. The distribution script embeds the `testflight` environment. A local
Release build defaults to `local`, and a TestFlight build promoted to the App
Store keeps its embedded environment. Events use the `app`, `app_platform`,
and `build` tags. The host reports as `partybox` and the controller as `partypad`.

For first-release verification, use a local Release test build for each platform
with a temporary controlled crash after Sentry starts. Run it without a debugger,
then relaunch it to deliver the report. Upload that test build’s matching dSYMs.
Confirm that Sentry shows app function names and source line information in the
`local` environment and that the app, platform, and build tags identify the
test build. On macOS, also raise a temporary Objective-C exception from an AppKit
event handler. The app should terminate and report the exception after relaunch.
Use the shipping archives for the TestFlight upload.
