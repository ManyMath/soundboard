import 'capture_device.dart';

/// Hooks for what the native (FFI) backend's library cannot do by itself on
/// some platforms.
///
/// On Android, requesting `RECORD_AUDIO` needs the app's Activity and listing
/// inputs needs `AudioManager`, so `microphone_flutter` installs these there.
/// Elsewhere the native library answers itself, and pure-Dart programs leave
/// them null. Integrations import this from
/// `package:microphone_dart/platform_hooks.dart`; apps should leave these hooks
/// alone.
abstract final class NativePlatform {
  /// Whether the app holds microphone permission. Overrides the native
  /// library's answer when set.
  static Future<bool> Function()? checkPermission;

  /// Asks the user for microphone permission and returns whether it was
  /// granted. Overrides the native library's request when set.
  static Future<bool> Function()? requestPermission;

  /// Lists the input devices. Overrides the native library's list when set;
  /// each id must be one the native library accepts as a `deviceId`.
  static Future<List<CaptureDevice>> Function()? devices;
}
