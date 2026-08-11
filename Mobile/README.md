# Dropsift for iPhone and Apple Watch

## What is included

- A native SwiftUI iPhone app with Capture, Timeline, and Ask tabs.
- A native SwiftUI Watch app for one-tap voice-message recording.
- Background Watch-to-iPhone file delivery with a durable outgoing queue.
- One shared on-disk schema used by iPhone, Watch-originated captures, and Mac.
- On-device iPhone speech recognition, Vision OCR, PDF extraction, playback,
  editing, deletion, filters, local search, local answers, and deep-linked
  sources.

The minimum deployments are iOS 18 and watchOS 11. Foundation Models answers
activate on iOS 26 when Apple Intelligence is available; source-grounded
extractive answers remain available on other supported iPhones. The Ask screen
always shows the resolved engine and offers an explicit choice between
Automatic, Apple Intelligence, and retrieval-only Local source search.

## Install on your devices

1. Open `DropsiftMobile.xcodeproj` in Xcode.
2. Select the `DropsiftMobile` project, then set **Signing & Capabilities →
   Team** for both `DropsiftMobile` and `DropsiftWatch` if needed.
3. Connect and trust the iPhone paired with your Apple Watch.
4. Select that iPhone as the `DropsiftMobile` run destination and press Run.
5. If automatic Watch installation is disabled, open the Watch app on iPhone
   and install Dropsift under **Available Apps**.

The checked-in project is generated from `project.yml`. After changing the
spec, regenerate it with:

```sh
brew install xcodegen
scripts/generate-mobile-project.sh
```

With current iOS and watchOS simulator runtimes installed:

```sh
scripts/build-mobile.sh
```

For TestFlight or App Store distribution:

1. In **Xcode → Settings → Apple Accounts**, sign in with the Apple Account
   that owns the intended App Store Connect team.
2. Confirm **Signing & Capabilities → Team** selects that same team for both
   app targets.
3. Choose **Any iOS Device (arm64)** and use **Product → Archive**.
4. In Organizer, choose **Distribute App → App Store Connect → Upload**.

Apple requires a valid paid Developer Program team, a matching App Store
Connect app record, and valid signing. An unsigned IPA cannot be installed on
a normal iPhone or Apple Watch. The app declares that it does not use
non-exempt encryption, so App Store Connect should not repeatedly ask the
standard export-compliance question unless encryption is added later. Its
privacy manifest declares app-local preferences and no tracking or collected
data; update that declaration if the app's data practices change.

## Connect the shared library

On the iPhone's Capture tab, choose **Choose iCloud folder** and select:

- `iCloud Drive/Dropsift`, for current installs; or
- `iCloud Drive/Quill`, when the Mac still uses the compatible legacy folder.

iOS grants access to user-visible iCloud Drive folders through the system file
picker, so this one-time selection is intentional. Dropsift saves a
security-scoped bookmark and restores it on future launches. Captures remain
local and usable if the folder is not connected; connecting later merges them
without overwriting existing entries.

## Watch delivery lifecycle

1. The Watch asynchronously activates a record-only audio session and records
   a mono 16 kHz, 32 kbps AAC `.m4a` in its Application Support directory.
2. Stopping creates metadata and queues the file with `WCSession.transferFile`.
3. The iPhone moves the received temporary file into a durable inbox before
   the Watch Connectivity callback returns.
4. The phone imports it as
   `Recordings/<timestamp>-mobile-<id>/mic.m4a` plus `meta.json` and
   `title.txt`.
5. Successful on-device transcription adds the canonical `transcript.json`
   and `transcript.md`. Otherwise the Mac detects the unfinished recording and
   completes it with the existing Parakeet pipeline.

The Watch deletes its queued copy only after Watch Connectivity reports a
successful transfer. Opening either app later resumes pending work.

## Device validation checklist

Watch file transfer is not implemented by the simulator; use a physically
paired iPhone and Watch for the end-to-end check.

1. Disconnect the phone from the network, record on Watch, and stop.
2. Confirm the Watch shows the message as queued or saved.
3. Open Dropsift on iPhone and confirm the recording appears in Timeline.
4. Play it, wait for transcription, and ask a question using a phrase from it.
5. Tap the answer's source card and confirm it opens the highlighted segment.
6. Reconnect the network and open Dropsift on Mac; confirm the same recording
   appears and any pending multilingual transcription completes.

## Local validation

The cross-platform storage contract is covered by the root Swift test suite:

```sh
swift test
```

The Watch and iPhone targets use Swift 6 strict concurrency. A normal build
requires Xcode's matching iOS/watchOS runtime components even when compiling
for a physical device. If Xcode reports that CoreSimulator is older than
Xcode, install the macOS/Xcode software update and the watchOS platform in
**Xcode → Settings → Components**, then rerun the build.
