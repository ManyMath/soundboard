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

Building requires Rust (`rustup`). To remove even that for consumers, the repo
is set up for cargokit precompiled binaries:

- `native/microphone/cargokit.yaml` holds the public signing key and the
  release URL prefix.
- A release workflow builds and uploads signed binaries to
  `precompiled_<crate-hash>` releases on tag pushes. It needs a
  `CARGOKIT_PRIVATE_KEY` repository secret: the hex private key printed by
  `dart run build_tool gen-key` (keep it secret; never commit it).

Once a release exists, consuming builds download the matching signed binary
instead of invoking cargo; with none present, cargokit builds from source.
