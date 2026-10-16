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

The microphone is a protected resource; declare it in your app:

- **macOS / iOS**: add `NSMicrophoneUsageDescription` to `Info.plist`. On macOS
  also enable the audio-input entitlement
  (`com.apple.security.device.audio-input`) for sandboxed apps.
- **Android**: add `<uses-permission android:name="android.permission.RECORD_AUDIO"/>`
  to `AndroidManifest.xml`. Capture uses AAudio, available from Android 8.0
  (API 26); the plugin builds with Flutter's default `minSdk`, and on older
  devices recording fails with a `CaptureException`.

`Microphone.requestPermission()` shows the system prompt on Android, iOS,
macOS and the web, and `Microphone.record()` asks first by itself when
permission has not been granted, throwing `PermissionDeniedException` if the
user refuses. Linux and Windows do not gate capture. See the example app for
the platform configuration.

## Precompiled binaries

Building requires Rust (`rustup`). cargokit can download signed precompiled
binaries instead of invoking cargo, but this repo does not publish them yet
(there is no `rust/cargokit.yaml` or release workflow), so every
build compiles the crate from source.
