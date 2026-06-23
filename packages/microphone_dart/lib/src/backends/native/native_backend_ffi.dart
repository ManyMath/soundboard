import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../capture_backend.dart';
import '../../capture_device.dart';
import '../../capture_format.dart';
import '../../exceptions.dart';
import '../../file_writer.dart';
import '../../recording.dart';
import '../../wav.dart';

/// The default native backend on platforms with `dart:ffi`.
CaptureBackend? createNativeBackend() => FfiBackend();

// --- C ABI signatures, mirroring native/microphone/src/lib.rs ----------------

typedef _RecorderNewNative = Pointer<Void> Function();
typedef _RecorderFreeNative = Void Function(Pointer<Void>);
typedef _RecorderFree = void Function(Pointer<Void>);
typedef _StartNative =
    Uint64 Function(Pointer<Void>, Uint32, Uint32, Pointer<Utf8>);
typedef _Start = int Function(Pointer<Void>, int, int, Pointer<Utf8>);
typedef _ReadNative =
    IntPtr Function(Pointer<Void>, Uint64, Pointer<Int16>, Size);
typedef _Read = int Function(Pointer<Void>, int, Pointer<Int16>, int);
typedef _IdQueryNative = Int32 Function(Pointer<Void>, Uint64);
typedef _IdQuery = int Function(Pointer<Void>, int);
typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastError = Pointer<Utf8> Function();
typedef _DeviceCountNative = Int32 Function();
typedef _DeviceCount = int Function();
typedef _DeviceFieldNative = Int32 Function(Int32, Pointer<Utf8>, Size);
typedef _DeviceField = int Function(int, Pointer<Utf8>, int);
typedef _DeviceIsDefaultNative = Int32 Function(Int32);
typedef _DeviceIsDefault = int Function(int);

// Recording state codes mirrored from the native side. Only the error code is
// acted on here (0 recording / 1 stopped are inferred from our own lifecycle).
const int _stateError = 2;

/// Locates and opens the `microphone` shared library.
class NativeLibrary {
  /// Explicit path override, highest priority. Set before first use.
  static String? overridePath;

  static DynamicLibrary? _opened;
  static bool _attempted = false;

  static String get _fileName => switch (Platform.operatingSystem) {
    'windows' => 'microphone.dll',
    'macos' || 'ios' => 'libmicrophone.dylib',
    _ => 'libmicrophone.so',
  };

  /// Opens the library, caching the result. Returns `null` if it cannot be
  /// found/loaded -- never throws.
  static DynamicLibrary? open() {
    if (_attempted) return _opened;
    _attempted = true;
    for (final candidate in _candidates()) {
      try {
        _opened = DynamicLibrary.open(candidate);
        return _opened;
      } on Object {
        // Try the next candidate.
      }
    }
    // On Apple platforms the symbols are -force_load'd into the plugin's
    // framework, which is loaded into the host process for us -- so process()
    // resolves them even when DynamicLibrary.open cannot find the framework
    // path directly.
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final p = DynamicLibrary.process();
        p.lookup<NativeFunction<_RecorderNewNative>>('microphone_recorder_new');
        _opened = p;
      } on Object {
        // Fall through.
      }
    }
    return _opened;
  }

  static Iterable<String> _candidates() sync* {
    if (overridePath != null) yield overridePath!;
    final fromEnv = Platform.environment['MICROPHONE_LIB'];
    if (fromEnv != null && fromEnv.isNotEmpty) yield fromEnv;
    // Resolved via the OS loader path / Flutter app bundle.
    yield _fileName;
    // On macOS/iOS the symbols are -force_load'd into the plugin's framework.
    if (Platform.isMacOS || Platform.isIOS) {
      yield 'microphone_flutter.framework/microphone_flutter';
    }
    // Developer builds of the in-repo crate, searched from the cwd upward.
    var dir = Directory.current.absolute;
    for (var i = 0; i < 6; i++) {
      for (final profile in ['release', 'debug']) {
        yield '${dir.path}/native/microphone/target/$profile/$_fileName';
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
}

/// Bound entry points into the native library.
class _Bindings {
  _Bindings(DynamicLibrary lib)
    : recorderNew = lib.lookupFunction<_RecorderNewNative, _RecorderNewNative>(
        'microphone_recorder_new',
      ),
      recorderFree = lib.lookupFunction<_RecorderFreeNative, _RecorderFree>(
        'microphone_recorder_free',
      ),
      start = lib.lookupFunction<_StartNative, _Start>('microphone_start'),
      read = lib.lookupFunction<_ReadNative, _Read>('microphone_read'),
      state = lib.lookupFunction<_IdQueryNative, _IdQuery>('microphone_state'),
      sampleRate = lib.lookupFunction<_IdQueryNative, _IdQuery>(
        'microphone_sample_rate',
      ),
      channels = lib.lookupFunction<_IdQueryNative, _IdQuery>(
        'microphone_channels',
      ),
      pause = lib.lookupFunction<_IdQueryNative, _IdQuery>('microphone_pause'),
      resume = lib.lookupFunction<_IdQueryNative, _IdQuery>(
        'microphone_resume',
      ),
      stop = lib.lookupFunction<_IdQueryNative, _IdQuery>('microphone_stop'),
      recordingFree = lib.lookupFunction<_IdQueryNative, _IdQuery>(
        'microphone_recording_free',
      ),
      lastError = lib.lookupFunction<_LastErrorNative, _LastError>(
        'microphone_last_error',
      ),
      deviceCount = lib.lookupFunction<_DeviceCountNative, _DeviceCount>(
        'microphone_device_count',
      ),
      deviceId = lib.lookupFunction<_DeviceFieldNative, _DeviceField>(
        'microphone_device_id',
      ),
      deviceName = lib.lookupFunction<_DeviceFieldNative, _DeviceField>(
        'microphone_device_name',
      ),
      deviceIsDefault = lib
          .lookupFunction<_DeviceIsDefaultNative, _DeviceIsDefault>(
            'microphone_device_is_default',
          );

  final Pointer<Void> Function() recorderNew;
  final _RecorderFree recorderFree;
  final _Start start;
  final _Read read;
  final _IdQuery state;
  final _IdQuery sampleRate;
  final _IdQuery channels;
  final _IdQuery pause;
  final _IdQuery resume;
  final _IdQuery stop;
  final _IdQuery recordingFree;
  final _LastError lastError;
  final _DeviceCount deviceCount;
  final _DeviceField deviceId;
  final _DeviceField deviceName;
  final _DeviceIsDefault deviceIsDefault;
}

/// Captures audio by calling the native `microphone` library over FFI.
class FfiBackend extends CaptureBackend {
  _Bindings? _bindings;
  Pointer<Void> _recorder = nullptr;
  bool _available = false;
  bool _probed = false;

  @override
  String get name => 'ffi';

  @override
  int get priority => 100;

  @override
  bool get isAvailable {
    if (_probed) return _available;
    _probed = true;
    final lib = NativeLibrary.open();
    if (lib == null) return _available = false;
    try {
      _bindings = _Bindings(lib);
      _available = true;
    } on Object {
      _available = false;
    }
    return _available;
  }

  @override
  Future<void> initialize() async {
    if (!isAvailable) {
      throw const NoBackendAvailableException(
        'The microphone library could not be loaded.',
      );
    }
    if (_recorder != nullptr) return;
    _recorder = _bindings!.recorderNew();
    if (_recorder == nullptr) {
      throw CaptureException('microphone_recorder_new failed: ${_lastError()}');
    }
  }

  String _lastError() {
    final ptr = _bindings!.lastError();
    return ptr == nullptr ? 'unknown error' : ptr.toDartString();
  }

  // The OS gates microphone access at capture time (e.g. the macOS TCC prompt
  // on first use); there is no portable pure-Dart permission API, so report
  // true and let capture surface a denial. Flutter layers a real permission
  // check on top via microphone_flutter.
  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<CaptureDevice>> devices() async {
    if (!isAvailable) return const [];
    final b = _bindings!;
    final count = b.deviceCount();
    if (count <= 0) return const [];
    const cap = 512;
    final buf = malloc<Uint8>(cap).cast<Utf8>();
    try {
      final out = <CaptureDevice>[];
      for (var i = 0; i < count; i++) {
        final idLen = b.deviceId(i, buf, cap);
        if (idLen < 0) continue;
        final id = buf.toDartString(length: idLen);
        final nameLen = b.deviceName(i, buf, cap);
        final name = nameLen < 0 ? id : buf.toDartString(length: nameLen);
        out.add(
          CaptureDevice(
            id: id,
            label: name,
            isDefault: b.deviceIsDefault(i) == 1,
          ),
        );
      }
      return out;
    } finally {
      malloc.free(buf);
    }
  }

  @override
  Future<Recording> startRecording({
    CaptureFormat format = const CaptureFormat(),
    String? deviceId,
  }) async {
    if (_recorder == nullptr) await initialize();
    return FfiRecording._(this, format, deviceId);
  }

  @override
  Future<void> dispose() async {
    if (_recorder != nullptr) {
      _bindings!.recorderFree(_recorder);
      _recorder = nullptr;
    }
  }
}

/// A single FFI-backed recording. Polls `microphone_read` to drain captured PCM
/// into the [frames] stream and an accumulating buffer.
class FfiRecording implements Recording {
  FfiRecording._(this._backend, CaptureFormat requested, String? deviceId) {
    final cId = deviceId == null ? nullptr : deviceId.toNativeUtf8();
    try {
      _id = _b.start(_recorder, requested.sampleRate, requested.channels, cId);
    } finally {
      if (cId != nullptr) malloc.free(cId);
    }
    if (_id == 0) {
      throw CaptureException('capture failed: ${_backend._lastError()}');
    }
    final rate = _b.sampleRate(_recorder, _id);
    final ch = _b.channels(_recorder, _id);
    _format = requested.copyWith(
      sampleRate: rate > 0 ? rate : requested.sampleRate,
      channels: ch > 0 ? ch : requested.channels,
    );
    _state = RecordingState.recording;
    // 16384 samples is generous headroom over the ~2205 samples produced per
    // 50 ms at 44.1 kHz mono, so a poll never leaves much behind.
    _buf = malloc<Int16>(_readCap);
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) => _drain());
  }

  static const int _readCap = 16384;

  final FfiBackend _backend;
  late final CaptureFormat _format;
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();

  int _id = 0;
  late final Pointer<Int16> _buf;
  Timer? _poll;
  RecordingState _state = RecordingState.idle;
  Uint8List? _finalWav;

  _Bindings get _b => _backend._bindings!;
  Pointer<Void> get _recorder => _backend._recorder;

  @override
  RecordingState get state => _state;

  @override
  bool get isRecording => _state == RecordingState.recording;

  @override
  CaptureFormat get format => _format;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Uint8List get pcm => _pcm.toBytes();

  @override
  Duration get duration {
    final frameCount = _pcm.length ~/ _format.bytesPerFrame;
    return Duration(
      microseconds:
          frameCount * Duration.microsecondsPerSecond ~/ _format.sampleRate,
    );
  }

  /// Copies whatever the native side has captured since the last poll into the
  /// PCM buffer and the frame stream.
  void _drain() {
    if (_id == 0 || _state == RecordingState.disposed) return;
    final native = _b.state(_recorder, _id);
    if (native == _stateError) {
      _stopPolling();
      _state = RecordingState.stopped;
      if (!_frames.isClosed) {
        _frames.addError(CaptureException(_backend._lastError()));
        _frames.close();
      }
      return;
    }
    final n = _b.read(_recorder, _id, _buf, _readCap);
    if (n <= 0) return;
    // Copy the n captured Int16 samples out of native memory as raw S16LE
    // bytes. _buf.asTypedList is a view over native memory that the next poll
    // overwrites, so we make a private copy. The samples are LE on every
    // platform we target.
    final view = _buf.asTypedList(n); // Int16List over native memory
    final bytes = Uint8List(n * 2)
      ..setRange(0, n * 2, view.buffer.asUint8List(view.offsetInBytes, n * 2));
    _pcm.add(bytes);
    if (!_frames.isClosed) _frames.add(bytes);
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  Future<void> pause() async {
    // The native side discards captured input while paused, so the paused
    // interval is dropped. The poll keeps running but reads nothing.
    if (_state == RecordingState.recording && _id != 0) {
      _b.pause(_recorder, _id);
      _state = RecordingState.paused;
    }
  }

  @override
  Future<void> resume() async {
    if (_state == RecordingState.paused && _id != 0) {
      _b.resume(_recorder, _id);
      _state = RecordingState.recording;
    }
  }

  @override
  Future<Uint8List> stop() async {
    if (_finalWav != null) return _finalWav!;
    if (_state == RecordingState.disposed) {
      return _finalWav = wavFromPcm(_pcm.toBytes(), _format);
    }
    _stopPolling();
    if (_id != 0) {
      _b.stop(_recorder, _id);
      // Final drain of anything captured since the last poll.
      _drain();
    }
    _state = RecordingState.stopped;
    if (!_frames.isClosed) await _frames.close();
    return _finalWav = wavFromPcm(_pcm.toBytes(), _format);
  }

  @override
  Future<String> stopToFile(String path) async {
    final wav = await stop();
    await writeBytes(path, wav);
    return path;
  }

  @override
  Future<void> dispose() async {
    _stopPolling();
    if (_id != 0) {
      _b.recordingFree(_recorder, _id);
      _id = 0;
    }
    if (_state != RecordingState.disposed) {
      malloc.free(_buf);
    }
    _state = RecordingState.disposed;
    if (!_frames.isClosed) await _frames.close();
  }
}
