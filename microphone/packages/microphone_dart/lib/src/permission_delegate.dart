import 'microphone.dart';

/// Microphone permission checks supplied by a host, for platforms where they
/// need platform code that pure Dart cannot reach.
///
/// The FFI backend has no permission API of its own. That is fine where the OS
/// prompts when capture starts (macOS, iOS), but Android's `RECORD_AUDIO` is a
/// runtime permission the app has to request itself. A host package that can
/// call into the platform -- `microphone_flutter` does on Android -- implements
/// this and installs it as [Microphone.permissionDelegate].
abstract interface class MicrophonePermissionDelegate {
  /// Whether the app currently holds microphone permission, without prompting.
  Future<bool> hasPermission();

  /// Prompts for microphone permission if it is not already held, returning
  /// whether it was granted.
  Future<bool> requestPermission();
}
