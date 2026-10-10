# microphone_flutter

Flutter integration for [`microphone_dart`](../microphone_dart):
cross-platform microphone capture with the goal of no system dependencies for 
users or devs to install.

This package builds the shared `microphone` Rust crate automatically (via
[cargokit](https://github.com/ManyMath/cargokit)) and bundles it with your app,
then re-exports the full `microphone_dart` API.

```dart
import 'package:microphone_flutter/microphone_flutter.dart';

await MicrophoneFlutter.ensureInitialized();
if (await Microphone.requestPermission()) {
  final recording = await Microphone.record();
  // ... later ...
  final wav = await recording.stop();
}
```

## Permissions

The microphone is a protected resource:

- **Android**: the plugin declares `RECORD_AUDIO`, which merges into your app's
  manifest. It is a runtime permission, so call `Microphone.requestPermission()`
  before recording; it shows the system dialog when needed and returns whether
  access was granted. Without it, capture fails or records silence.
- **macOS / iOS**: add `NSMicrophoneUsageDescription` to `Info.plist`. On macOS
  also enable the audio-input entitlement
  (`com.apple.security.device.audio-input`) for sandboxed apps. The OS prompts
  on first capture.
- **Web**: the browser prompts via getUserMedia.

See the example app for working configuration.

## Precompiled binaries

Building requires Rust (`rustup`). Precompiled binaries are not configured:
to offer them, add a `native/microphone/cargokit.yaml` with a
`precompiled_binaries` `url_prefix` and the public key from
`dart run build_tool gen-key`, and publish signed `precompiled_<crate-hash>`
releases there.
