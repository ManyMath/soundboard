import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:microphone_dart/microphone_dart.dart' show CaptureFormat;

import '../s16le.dart';
import '../virtual_microphone.dart';

/// A Windows virtual-cable operation failed.
class WindowsVirtualMicException implements Exception {
  const WindowsVirtualMicException(this.message);
  final String message;
  @override
  String toString() => 'WindowsVirtualMicException: $message';
}

/// The platform, native sound library, or named virtual cable is unavailable.
class WindowsVirtualMicUnavailableException extends WindowsVirtualMicException {
  const WindowsVirtualMicUnavailableException([
    super.message =
        'Windows virtual microphone is unavailable: install VB-CABLE, then '
        'make sure the sound_flutter native library is bundled.',
  ]);
}

typedef _SinkOpenNative = Pointer<Void> Function(Pointer<Utf8>, Uint32, Uint32);
typedef _SinkOpen = Pointer<Void> Function(Pointer<Utf8>, int, int);
typedef _SinkWriteNative = Int32 Function(Pointer<Void>, Pointer<Int16>, Size);
typedef _SinkWrite = int Function(Pointer<Void>, Pointer<Int16>, int);
typedef _SinkCloseNative = Void Function(Pointer<Void>);
typedef _SinkClose = void Function(Pointer<Void>);
typedef _SinkLastErrorNative = Pointer<Utf8> Function();
typedef _SinkLastError = Pointer<Utf8> Function();

final class _SinkBindings {
  _SinkBindings._(this.open, this.write, this.close, this.lastError);

  final _SinkOpen open;
  final _SinkWrite write;
  final _SinkClose close;
  final _SinkLastError lastError;

  static _SinkBindings? _cached;

  static _SinkBindings? load() {
    if (_cached case final cached?) return cached;
    final library = _openLibrary();
    if (library == null) return null;
    try {
      return _cached = _SinkBindings._(
        library.lookupFunction<_SinkOpenNative, _SinkOpen>('sound_sink_open'),
        library.lookupFunction<_SinkWriteNative, _SinkWrite>(
          'sound_sink_write',
        ),
        library.lookupFunction<_SinkCloseNative, _SinkClose>(
          'sound_sink_close',
        ),
        library.lookupFunction<_SinkLastErrorNative, _SinkLastError>(
          'sound_sink_last_error',
        ),
      );
    } on Object {
      return null;
    }
  }

  String lastErrorString() {
    final pointer = lastError();
    if (pointer == nullptr) return 'unknown error';
    final value = pointer.toDartString();
    return value.isEmpty ? 'unknown error' : value;
  }

  static DynamicLibrary? _openLibrary() {
    for (final candidate in _candidates()) {
      try {
        return DynamicLibrary.open(candidate);
      } on Object {
        // Try the next candidate.
      }
    }
    try {
      final process = DynamicLibrary.process();
      process.lookup<NativeFunction<_SinkOpenNative>>('sound_sink_open');
      return process;
    } on Object {
      return null;
    }
  }

  static Iterable<String> _candidates() sync* {
    final override = Platform.environment['SOUND_DART_LIB'];
    if (override != null && override.isNotEmpty) yield override;
    const fileName = 'sound_cli.dll';
    yield fileName;
    var directory = Directory.current.absolute;
    for (var i = 0; i < 6; i++) {
      for (final profile in const <String>['release', 'debug']) {
        yield '${directory.path}/native/sound_cli/target/$profile/$fileName';
        yield '${directory.path}/sound/native/sound_cli/target/$profile/$fileName';
      }
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }
  }
}

/// Feeds a Windows virtual audio cable as a microphone.
///
/// VB-CABLE names the endpoint written by applications `CABLE Input` and the
/// paired recording endpoint selected by Discord/games `CABLE Output`.
class WindowsVirtualMic implements VirtualMicrophone {
  WindowsVirtualMic._(
    this._bindings,
    this._sink,
    this.sinkDeviceName,
    this.deviceName,
    this.format,
  );

  static const String defaultSinkDeviceName =
      'CABLE Input (VB-Audio Virtual Cable)';
  static const String defaultDeviceName =
      'CABLE Output (VB-Audio Virtual Cable)';

  /// Playback endpoint that Soundboard writes.
  final String sinkDeviceName;

  /// Recording endpoint that microphone-consuming applications select.
  @override
  final String deviceName;

  @override
  final CaptureFormat format;

  final _SinkBindings _bindings;
  Pointer<Void> _sink;
  bool _feeding = false;
  bool _disposed = false;
  StreamSubscription<Uint8List>? _subscription;
  Completer<void>? _feedDone;
  Pointer<Int16> _scratch = nullptr;
  int _scratchLength = 0;

  /// Whether the Windows native library can open [sinkDeviceName].
  static Future<bool> isSupported({
    String sinkDeviceName = defaultSinkDeviceName,
  }) async {
    if (!Platform.isWindows) return false;
    final bindings = _SinkBindings.load();
    if (bindings == null) return false;
    final name = sinkDeviceName.toNativeUtf8();
    try {
      final sink = bindings.open(name, 48000, 2);
      if (sink == nullptr) return false;
      bindings.close(sink);
      return true;
    } on Object {
      return false;
    } finally {
      malloc.free(name);
    }
  }

  /// Opens a named virtual cable playback endpoint.
  static Future<WindowsVirtualMic> create({
    String sinkDeviceName = defaultSinkDeviceName,
    String deviceName = defaultDeviceName,
    CaptureFormat format = const CaptureFormat(sampleRate: 48000, channels: 2),
  }) async {
    if (!Platform.isWindows) {
      throw const WindowsVirtualMicUnavailableException();
    }
    final bindings = _SinkBindings.load();
    if (bindings == null) {
      throw const WindowsVirtualMicUnavailableException();
    }
    final name = sinkDeviceName.toNativeUtf8();
    final Pointer<Void> sink;
    try {
      sink = bindings.open(name, format.sampleRate, format.channels);
    } finally {
      malloc.free(name);
    }
    if (sink == nullptr) {
      throw WindowsVirtualMicException(
        'could not open "$sinkDeviceName": ${bindings.lastErrorString()}',
      );
    }
    return WindowsVirtualMic._(
      bindings,
      sink,
      sinkDeviceName,
      deviceName,
      format,
    );
  }

  @override
  Future<void> feed(Stream<Uint8List> pcm) {
    if (_disposed) {
      throw const WindowsVirtualMicException('virtual mic disposed');
    }
    if (_feeding) throw StateError('feed() already called');
    _feeding = true;
    final done = _feedDone = Completer<void>();
    _subscription = pcm.listen(
      _writeChunk,
      onError: (Object error, StackTrace stackTrace) {
        if (!done.isCompleted) done.completeError(error, stackTrace);
        unawaited(dispose());
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    done.future.ignore();
    return done.future;
  }

  void _writeChunk(Uint8List chunk) {
    if (_disposed || _sink == nullptr) return;
    final samples = s16leSamples(chunk);
    if (samples.isEmpty) return;
    final buffer = _ensureScratch(samples.length);
    buffer.asTypedList(samples.length).setAll(0, samples);
    if (_bindings.write(_sink, buffer, samples.length) < 0) {
      final error = WindowsVirtualMicException(
        'writing to "$sinkDeviceName" failed: ${_bindings.lastErrorString()}',
      );
      final done = _feedDone;
      if (done != null && !done.isCompleted) done.completeError(error);
      unawaited(dispose());
    }
  }

  Pointer<Int16> _ensureScratch(int samples) {
    if (samples <= _scratchLength) return _scratch;
    if (_scratch != nullptr) malloc.free(_scratch);
    _scratch = malloc<Int16>(samples);
    _scratchLength = samples;
    return _scratch;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final done = _feedDone;
    if (done != null && !done.isCompleted) done.complete();
    await _subscription?.cancel();
    _subscription = null;
    if (_sink != nullptr) {
      _bindings.close(_sink);
      _sink = nullptr;
    }
    if (_scratch != nullptr) {
      malloc.free(_scratch);
      _scratch = nullptr;
      _scratchLength = 0;
    }
  }
}
