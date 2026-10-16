## 0.0.2

- Fixes the build: 0.0.1 could not build in any app, because its platform
  builds pointed at the Rust crate outside the published package. The crate
  now ships in the package (`rust/`).
- Android builds with Gradle 9 (the vendored cargokit Gradle plugin no longer
  uses the removed `Project.exec`) and with Flutter's default `minSdk`; on
  devices older than Android 8.0 recording fails with a `CaptureException`.
- Android: `Microphone.requestPermission()` asks for `RECORD_AUDIO`, and
  `Microphone.record()` asks by itself when it is missing; `Microphone.devices()`
  lists the inputs and `record(deviceId: ...)` selects one.
- Bundles the native capture fixes listed in `microphone_dart`'s changelog,
  including the macOS/iOS permission prompt.
- Requires Flutter 3.38+ (matching the Dart ^3.10 floor); the macOS pod targets
  10.15; podspec metadata filled in.
- Example app: Record is disabled while a recording starts, and capture errors
  stop the recording instead of leaving the page stuck.

## 0.0.1

- Flutter integration for `microphone_dart`: builds the shared `microphone`
  Rust crate via cargokit and bundles it. Re-exports the `microphone_dart`
  API and adds `MicrophoneFlutter.ensureInitialized()`.
- Documents the required platform permissions (Info.plist
  `NSMicrophoneUsageDescription` and the macOS audio-input entitlement on
  Apple).
- Android: declares `RECORD_AUDIO` and requests it at runtime through
  `Microphone.requestPermission()`, via a small Kotlin plugin. Requires
  Flutter 3.44 or later, which applies Kotlin to plugins itself. Run
  `flutter clean` once in an app built before this change: Flutter only
  regenerates its Dart plugin registrant when the package config changes.
- Example app with a record/stop UI and a live input-level meter.
