import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:microphone_dart/microphone_dart.dart' show CaptureFormat;

import '../s16le.dart';
import '../virtual_microphone.dart';

/// Thrown when a CoreAudio virtual microphone cannot be created or operated.
class CoreAudioException implements Exception {
  const CoreAudioException(this.message);
  final String message;
  @override
  String toString() => 'CoreAudioException: $message';
}

/// Thrown by [CoreAudioVirtualMic.create] when the environment cannot host one
/// (not macOS, the native sink library is not loadable, or the loopback device
/// is absent).
class CoreAudioUnavailableException extends CoreAudioException {
  const CoreAudioUnavailableException([
    super.message =
        'CoreAudio virtual microphone is unavailable: needs macOS with a '
        'loopback audio device (install one with `brew install '
        'blackhole-2ch`) and the built sound_cli native library.',
  ]);
}

// --- C ABI signatures, mirroring native/sound_cli/src/lib.rs --------------

typedef _SinkOpenNative = Pointer<Void> Function(Pointer<Utf8>, Uint32, Uint32);
typedef _SinkOpen = Pointer<Void> Function(Pointer<Utf8>, int, int);
typedef _SinkWriteNative = Int32 Function(Pointer<Void>, Pointer<Int16>, Size);
typedef _SinkWrite = int Function(Pointer<Void>, Pointer<Int16>, int);
typedef _SinkCloseNative = Void Function(Pointer<Void>);
typedef _SinkClose = void Function(Pointer<Void>);
typedef _SinkLastErrorNative = Pointer<Utf8> Function();
typedef _SinkLastError = Pointer<Utf8> Function();

/// Locates and opens the `sound_cli` shared library and binds the
/// `sound_sink_*` entry points. Returns null when it cannot be loaded -- never
/// throws -- so [CoreAudioVirtualMic.isSupported] can degrade gracefully.
class _SinkBindings {
  _SinkBindings._(this.open, this.write, this.close, this.lastError);

  final _SinkOpen open;
  final _SinkWrite write;
  final _SinkClose close;
  final _SinkLastError lastError;

  static bool _attempted = false;
  static String? _attemptedOverride;
  static _SinkBindings? _cached;

  /// Explicit path override for the dylib, highest priority. Set before use.
  static String? overridePath;

  static _SinkBindings? load() {
    // A successful load is cached forever; a failed one is retried only when
    // [overridePath] has changed since the attempt (so setting it after a
    // failed probe is not silently ignored).
    if (_cached != null) return _cached;
    if (_attempted && overridePath == _attemptedOverride) return null;
    _attempted = true;
    _attemptedOverride = overridePath;
    final lib = _openLibrary();
    if (lib == null) return null;
    try {
      _cached = _SinkBindings._(
        lib.lookupFunction<_SinkOpenNative, _SinkOpen>('sound_sink_open'),
        lib.lookupFunction<_SinkWriteNative, _SinkWrite>('sound_sink_write'),
        lib.lookupFunction<_SinkCloseNative, _SinkClose>('sound_sink_close'),
        lib.lookupFunction<_SinkLastErrorNative, _SinkLastError>(
          'sound_sink_last_error',
        ),
      );
    } on Object {
      _cached = null;
    }
    return _cached;
  }

  /// The last sink error on the CURRENT thread. Errors are stored
  /// thread-locally on the native side, so this must be called synchronously
  /// after the failing call -- an intervening `await` may resume on another
  /// thread and read an empty slot.
  String lastErrorString() {
    final p = lastError();
    if (p == nullptr) return 'unknown error';
    final s = p.toDartString();
    return s.isEmpty ? 'unknown error' : s;
  }

  static DynamicLibrary? _openLibrary() {
    for (final candidate in _candidates()) {
      try {
        return DynamicLibrary.open(candidate);
      } on Object {
        // Try the next candidate.
      }
    }
    // The symbols may already be loaded into the process (e.g. force_load'd
    // into a Flutter plugin framework); probe one to confirm.
    try {
      final p = DynamicLibrary.process();
      p.lookup<NativeFunction<_SinkOpenNative>>('sound_sink_open');
      return p;
    } on Object {
      return null;
    }
  }

  // Mirrors the search order in sound_dart's NativeLibrary loader, so a
  // developer build of the in-repo crate is found from the cwd upward.
  static Iterable<String> _candidates() sync* {
    if (overridePath != null) yield overridePath!;
    final fromEnv = Platform.environment['SOUND_DART_LIB'];
    if (fromEnv != null && fromEnv.isNotEmpty) yield fromEnv;
    const fileName = 'libsound_cli.dylib';
    yield fileName;
    yield 'sound_flutter.framework/sound_flutter';
    var dir = Directory.current.absolute;
    for (var i = 0; i < 6; i++) {
      for (final profile in ['release', 'debug']) {
        yield '${dir.path}/native/sound_cli/target/$profile/$fileName';
        yield '${dir.path}/sound/native/sound_cli/target/$profile/$fileName';
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
}

/// A macOS virtual microphone: routes the soundboard mix into a loopback audio
/// device (BlackHole by default) so other applications -- a call, a stream, a
/// browser -- can select that device as their input.
///
/// Unlike the Linux PipeWire path there is no command-line feeder on macOS, so
/// this writes the mix into the device through the native `sound_cli` CoreAudio
/// sink. The loopback device itself is an external system component the user
/// installs once (`brew install blackhole-2ch`), the same way the PipeWire
/// tools are installed on Linux.
///
/// ```dart
/// final vmic = await CoreAudioVirtualMic.create(format: fmt);
/// final recording = await board.asMicrophoneBackend().startRecording(
///   format: fmt,
/// );
/// unawaited(vmic.feed(recording.frames));
/// // ... the app now hears the soundboard on the "BlackHole 2ch" mic ...
/// await vmic.dispose();
/// ```
class CoreAudioVirtualMic implements VirtualMicrophone {
  CoreAudioVirtualMic._(
    this._bindings,
    this._sink,
    this.deviceName,
    this.format,
  );

  /// The default loopback device routed into. BlackHole 2ch is a maintained,
  /// signed/notarized loopback installable with `brew install blackhole-2ch`.
  static const String defaultDeviceName = 'BlackHole 2ch';

  /// The audio device apps select as their input.
  @override
  final String deviceName;

  /// The format streamed into the device.
  @override
  final CaptureFormat format;

  final _SinkBindings _bindings;
  Pointer<Void> _sink;
  bool _feeding = false;
  bool _disposed = false;
  StreamSubscription<Uint8List>? _sub;
  Completer<void>? _feedDone;
  Pointer<Int16> _scratch = nullptr;
  int _scratchLen = 0;
  late final _frames = S16leFrames(format.channels);

  /// Whether this environment can host a CoreAudio virtual microphone: macOS,
  /// with the native sink library loadable and the loopback [deviceName]
  /// present. Never throws.
  static Future<bool> isSupported({
    String deviceName = defaultDeviceName,
  }) async {
    if (!Platform.isMacOS) return false;
    final b = _SinkBindings.load();
    if (b == null) return false;
    // Probe the device by opening (and immediately closing) a sink. open() does
    // not start audio -- the queue only runs on the first write -- so this is a
    // cheap presence check.
    final namePtr = deviceName.toNativeUtf8();
    try {
      // The probe rate/channels are irrelevant to a presence check; open() only
      // fails when the device is missing, not on format. 48 kHz stereo matches
      // the default.
      final sink = b.open(namePtr, 48000, 2);
      if (sink == nullptr) return false;
      b.close(sink);
      return true;
    } on Object {
      return false;
    } finally {
      malloc.free(namePtr);
    }
  }

  /// Locates the loopback [deviceName] and opens the native sink on it. Throws
  /// [CoreAudioUnavailableException] when [isSupported] is false, and
  /// [CoreAudioException] if the device cannot be opened.
  static Future<CoreAudioVirtualMic> create({
    String deviceName = defaultDeviceName,
    CaptureFormat format = const CaptureFormat(sampleRate: 48000, channels: 2),
  }) async {
    if (!Platform.isMacOS) throw const CoreAudioUnavailableException();
    final b = _SinkBindings.load();
    if (b == null) throw const CoreAudioUnavailableException();

    final namePtr = deviceName.toNativeUtf8();
    final Pointer<Void> sink;
    try {
      sink = b.open(namePtr, format.sampleRate, format.channels);
    } finally {
      malloc.free(namePtr);
    }
    if (sink == nullptr) {
      throw CoreAudioException(
        'could not open device "$deviceName": ${b.lastErrorString()}',
      );
    }
    return CoreAudioVirtualMic._(b, sink, deviceName, format);
  }

  /// Streams [pcm] (interleaved S16LE frames at [format]) into the device.
  /// Call once.
  ///
  /// The returned future completes when [pcm] closes or [dispose] is called,
  /// and completes with a [CoreAudioException] if the device stops accepting
  /// audio (e.g. it was removed) or [pcm] emits an error. Callers that keep
  /// running while feeding should not `await` it inline:
  ///
  /// ```dart
  /// unawaited(vmic.feed(recording.frames));
  /// ```
  @override
  Future<void> feed(Stream<Uint8List> pcm) {
    if (_disposed) throw const CoreAudioException('virtual mic disposed');
    if (_feeding) throw StateError('feed() already called');
    _feeding = true;
    final done = _feedDone = Completer<void>();
    _sub = pcm.listen(
      _writeChunk,
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
        unawaited(dispose());
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    // Errors surface to callers that await/listen; a caller that fires and
    // forgets must not crash the app with an unhandled async error.
    final future = done.future;
    future.ignore();
    return future;
  }

  void _writeChunk(Uint8List chunk) {
    if (_disposed || _sink == nullptr) return;
    final samples = _frames.take(chunk);
    if (samples.isEmpty) return;
    final buf = _ensureScratch(samples.length);
    buf.asTypedList(samples.length).setAll(0, samples);
    final n = _bindings.write(_sink, buf, samples.length);
    if (n < 0) {
      // A write failure (e.g. the device went away) ends feeding; capture the
      // error synchronously (the native slot is thread-local), surface it on
      // the feed future, and tear down rather than spamming the device.
      final err = CoreAudioException(
        'writing to "$deviceName" failed: ${_bindings.lastErrorString()}',
      );
      final done = _feedDone;
      if (done != null && !done.isCompleted) done.completeError(err);
      unawaited(dispose());
    }
  }

  Pointer<Int16> _ensureScratch(int samples) {
    if (samples <= _scratchLen) return _scratch;
    if (_scratch != nullptr) malloc.free(_scratch);
    _scratch = malloc<Int16>(samples);
    _scratchLen = samples;
    return _scratch;
  }

  /// Closes the sink and stops feeding. Idempotent. Completes a pending
  /// [feed] future.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final done = _feedDone;
    if (done != null && !done.isCompleted) done.complete();
    await _sub?.cancel();
    _sub = null;
    if (_sink != nullptr) {
      _bindings.close(_sink);
      _sink = nullptr;
    }
    if (_scratch != nullptr) {
      malloc.free(_scratch);
      _scratch = nullptr;
      _scratchLen = 0;
    }
  }
}
