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
/// The microphone is a protected resource:
///
/// - **Android**: this plugin declares `RECORD_AUDIO`, which merges into your
///   app's manifest. It is a runtime permission, so call
///   [Microphone.requestPermission] before recording: it shows the system
///   dialog when needed and returns whether access was granted. Without it,
///   capture fails or records silence.
/// - **macOS / iOS**: add `NSMicrophoneUsageDescription` to the app's
///   `Info.plist` (a short reason shown in the system prompt). On macOS also
///   enable the "Audio Input" capability / `com.apple.security.device.audio-input`
///   entitlement for sandboxed apps. The OS prompts the first time capture
///   starts; [Microphone.requestPermission] returns true without prompting.
/// - **Web**: the browser prompts when [Microphone.requestPermission] or the
///   first recording calls getUserMedia.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:microphone_dart/microphone_dart.dart';

export 'package:microphone_dart/microphone_dart.dart';

/// Flutter-side conveniences over the `microphone_dart` registry.
abstract final class MicrophoneFlutter {
  /// Hooks up Android's runtime microphone permission.
  ///
  /// Flutter's plugin registrant calls this at startup; apps do not need to.
  static void registerWith() => _installPermissionDelegate();

  /// Ensures a capture backend is selected and ready.
  ///
  /// On native platforms `microphone_dart` already auto-registers the FFI
  /// backend that loads the bundled `microphone` library; this initializes it
  /// eagerly so the first [Microphone.record] has no setup latency, and
  /// surfaces load errors early. Returns the name of the active backend (e.g.
  /// `ffi`, `web`, or `silent` when no microphone is available).
  static Future<String> ensureInitialized() async {
    _installPermissionDelegate();
    final backend = Microphone.backend;
    if (backend.isAvailable) {
      await backend.initialize();
    }
    return backend.name;
  }

  // A delegate the app installed itself is left in place.
  static void _installPermissionDelegate() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    Microphone.permissionDelegate ??= const _AndroidPermissions();
  }
}

/// Asks the plugin's Kotlin side about `RECORD_AUDIO`.
class _AndroidPermissions implements MicrophonePermissionDelegate {
  const _AndroidPermissions();

  static const _channel = MethodChannel('microphone_flutter/permission');

  @override
  Future<bool> hasPermission() async =>
      await _channel.invokeMethod<bool>('hasPermission') ?? false;

  @override
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;
}
