import 'capture_device.dart';
import 'capture_format.dart';
import 'recording.dart';

/// A pluggable provider of microphone capture for a given platform/technique.
///
/// `microphone_dart` is deliberately backend-agnostic: native platforms and
/// CLI tools capture over FFI, the web uses getUserMedia, and other techniques
/// can be layered on top. Several backends can be registered at once; the
/// active one is chosen by [isAvailable] and [priority] (see `Microphone`).
abstract class CaptureBackend {
  /// A short, stable identifier (e.g. `ffi`, `web`, `silent`).
  String get name;

  /// Whether this backend can run in the current environment.
  ///
  /// Should be cheap and side-effect free; it is consulted during backend
  /// selection. For example the FFI backend reports `false` when the native
  /// library cannot be located/loaded. This does not consider permission --
  /// access may still be denied at [startRecording] time.
  bool get isAvailable;

  /// Selection weight when multiple backends are available; higher wins.
  int get priority;

  /// Prepares the backend for use. Called once before the first recording.
  ///
  /// Must be idempotent -- selection may initialize a backend that was already
  /// initialized.
  Future<void> initialize();

  /// Whether the app currently holds microphone permission.
  ///
  /// On platforms without a permission model this is always true. Some backends
  /// can only answer after a request; treat a false here as "ask first".
  Future<bool> hasPermission();

  /// Requests microphone permission, returning whether it was granted.
  ///
  /// On platforms without a permission model this returns true without
  /// prompting. [startRecording] requests permission itself when needed; call
  /// this only to prompt ahead of time.
  Future<bool> requestPermission();

  /// Lists the available input devices.
  ///
  /// The first call may require permission to return device labels (browsers
  /// hide them until access is granted). Returns an empty list if enumeration
  /// is unsupported; the default device is still used by [startRecording].
  Future<List<CaptureDevice>> devices();

  /// Starts capturing in [format] and returns a controllable [Recording].
  ///
  /// [deviceId] selects an input from [devices]; when null the system default
  /// is used. Throws [PermissionDeniedException] if access is refused and
  /// [CaptureException] on a capture failure.
  Future<Recording> startRecording({CaptureFormat format, String? deviceId});

  /// Releases any global resources held by the backend.
  Future<void> dispose();
}
