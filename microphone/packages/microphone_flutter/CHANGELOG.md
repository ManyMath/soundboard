## 0.0.1

- Flutter integration for `microphone_dart`: builds the shared `microphone`
  Rust crate via cargokit and bundles it. Re-exports the `microphone_dart`
  API and adds `MicrophoneFlutter.ensureInitialized()`.
- Documents the required platform permissions (Info.plist
  `NSMicrophoneUsageDescription` and the macOS audio-input entitlement on
  Apple; `RECORD_AUDIO` on Android).
- Example app with a record/stop UI and a live input-level meter.
