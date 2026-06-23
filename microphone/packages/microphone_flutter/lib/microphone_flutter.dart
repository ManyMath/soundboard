/// Flutter integration for the `microphone_dart` package.
///
/// This package contributes the native `microphone` library to your Flutter app
/// (built automatically via cargokit) and re-exports the full
/// `microphone_dart` API. In most cases you only need the re-exported
/// [Microphone] entry point:
///
/// ```dart
/// import 'package:microphone_flutter/microphone_flutter.dart';
///
/// await MicrophoneFlutter.ensureInitialized();
/// if (await Microphone.requestPermission()) {
///   final recording = await Microphone.record();
///   // ... later ...
///   final wav = await recording.stop();
/// }
/// ```
///
/// ## Platform permissions
///
/// The microphone is a protected resource; your app must declare it:
///
/// - **macOS / iOS**: add `NSMicrophoneUsageDescription` to the app's
///   `Info.plist` (a short reason shown in the system prompt). On macOS also
///   enable the "Audio Input" capability / `com.apple.security.device.audio-input`
///   entitlement for sandboxed apps.
/// - **Android**: add `<uses-permission android:name="android.permission.RECORD_AUDIO"/>`
///   to `AndroidManifest.xml`.
///
/// The OS shows its permission prompt the first time capture starts. The web
/// backend prompts via getUserMedia.
library;

import 'package:microphone_dart/microphone_dart.dart';

export 'package:microphone_dart/microphone_dart.dart';

/// Flutter-side conveniences over the `microphone_dart` registry.
abstract final class MicrophoneFlutter {
  /// Ensures a capture backend is selected and ready.
  ///
  /// On native platforms `microphone_dart` already auto-registers the FFI
  /// backend that loads the bundled `microphone` library; this initializes it
  /// eagerly so the first [Microphone.record] has no setup latency, and
  /// surfaces load errors early. Returns the name of the active backend (e.g.
  /// `ffi`, `web`, or `silent` when no microphone is available).
  static Future<String> ensureInitialized() async {
    final backend = Microphone.backend;
    if (backend.isAvailable) {
      await backend.initialize();
    }
    return backend.name;
  }
}
