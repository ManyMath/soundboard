import 'backends/native/native_backend.dart';
import 'backends/silent_backend.dart';
import 'capture_backend.dart';
import 'capture_device.dart';
import 'capture_format.dart';
import 'exceptions.dart';
import 'recording.dart';

/// Entry point for recording audio.
///
/// `microphone_dart` keeps a registry of [CaptureBackend]s and picks the
/// best available one for the current environment (highest
/// [CaptureBackend.priority] among those whose [CaptureBackend.isAvailable] is
/// true). Apps can register extra backends or pin a specific one.
///
/// ```dart
/// final recording = await Microphone.record();
/// await Future<void>.delayed(const Duration(seconds: 3));
/// final wav = await recording.stop();
/// ```
class Microphone {
  Microphone._();

  static final List<CaptureBackend> _backends = [];
  static final Set<CaptureBackend> _initialized = Set.identity();
  static CaptureBackend? _active;
  static bool _defaultsRegistered = false;

  /// Registers the backends that ship with `microphone_dart`.
  ///
  /// Backends from outside packages register themselves; this only seeds the
  /// always-present floor.
  static void _ensureDefaults() {
    if (_defaultsRegistered) return;
    _defaultsRegistered = true;
    // The platform's native backend (FFI on native, getUserMedia on web), then
    // the silent fallback that guarantees the API never lacks a backend.
    final native = createNativeBackend();
    if (native != null) registerBackend(native);
    registerBackend(SilentBackend());
  }

  /// All registered backends, in registration order.
  static List<CaptureBackend> get backends {
    _ensureDefaults();
    return List.unmodifiable(_backends);
  }

  /// Adds [backend] to the registry.
  ///
  /// Pass [makeActive] to select it immediately regardless of priority.
  /// Re-registering an instance is a no-op.
  static void registerBackend(
    CaptureBackend backend, {
    bool makeActive = false,
  }) {
    _ensureDefaults();
    if (!_backends.contains(backend)) _backends.add(backend);
    if (makeActive) {
      _active = backend;
    } else {
      // Force re-selection so a newly added, higher-priority backend wins.
      _active = null;
    }
  }

  /// The backend currently in use, selecting one on first access.
  ///
  /// Throws [NoBackendAvailableException] if nothing is available.
  static CaptureBackend get backend {
    _ensureDefaults();
    return _active ??= _select();
  }

  /// Pins a specific registered backend by [name].
  ///
  /// Throws [NoBackendAvailableException] if no backend with that name is
  /// registered.
  static void useBackend(String name) {
    _ensureDefaults();
    final match = _backends.where((b) => b.name == name);
    if (match.isEmpty) {
      throw NoBackendAvailableException(
        'No backend named "$name" is registered.',
      );
    }
    _active = match.first;
  }

  static CaptureBackend _select() {
    final available = _backends.where((b) => b.isAvailable).toList()
      ..sort((a, b) => b.priority.compareTo(a.priority));
    if (available.isEmpty) throw const NoBackendAvailableException();
    return available.first;
  }

  /// Whether the app currently holds microphone permission. See
  /// [CaptureBackend.hasPermission].
  static Future<bool> hasPermission() => backend.hasPermission();

  /// Requests microphone permission, returning whether it was granted. See
  /// [CaptureBackend.requestPermission].
  static Future<bool> requestPermission() => backend.requestPermission();

  /// Starts a recording with the active backend.
  /// Lists the available input devices on the active backend. See
  /// [CaptureBackend.devices].
  static Future<List<CaptureDevice>> devices() => backend.devices();

  ///
  /// [format] requests a sample rate / channel count / encoding; the device may
  /// force its own, so consult [Recording.format] for what is actually in
  /// effect. [deviceId] selects an input from [devices] (null = system
  /// default). Throws [PermissionDeniedException] if access is refused.
  static Future<Recording> record({
    CaptureFormat format = const CaptureFormat(),
    String? deviceId,
  }) async {
    final b = backend;
    if (!_initialized.contains(b)) {
      await b.initialize();
      _initialized.add(b);
    }
    return b.startRecording(format: format, deviceId: deviceId);
  }

  /// Disposes the active backend and clears selection/registry.
  ///
  /// Primarily for tests; after this the defaults are re-seeded on next use.
  static Future<void> reset() async {
    for (final b in _initialized) {
      await b.dispose();
    }
    _initialized.clear();
    _backends.clear();
    _active = null;
    _defaultsRegistered = false;
  }
}
