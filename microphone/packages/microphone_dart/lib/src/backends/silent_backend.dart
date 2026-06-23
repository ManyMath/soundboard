import 'dart:async';
import 'dart:typed_data';

import '../capture_backend.dart';
import '../capture_device.dart';
import '../capture_format.dart';
import '../file_writer.dart';
import '../recording.dart';
import '../wav.dart';

/// A backend that captures silence.
///
/// It is the lowest-priority fallback so that `microphone_dart` never
/// crashes in environments without a microphone (CI, headless servers). It is
/// also a convenient test double: it produces well-formed, all-zero PCM at the
/// requested rate so file/stream plumbing can be exercised without hardware.
class SilentBackend extends CaptureBackend {
  SilentBackend({this.chunk = const Duration(milliseconds: 100)});

  /// How much audio each emitted frame chunk represents.
  final Duration chunk;

  /// Recordings handed out by this backend, in order. Useful in tests.
  final List<SilentRecording> started = [];

  @override
  String get name => 'silent';

  @override
  bool get isAvailable => true;

  @override
  int get priority => -1000;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<CaptureDevice>> devices() async => const [
    CaptureDevice(id: 'silent', label: 'Silent (no device)', isDefault: true),
  ];

  @override
  Future<Recording> startRecording({
    CaptureFormat format = const CaptureFormat(),
    String? deviceId,
  }) async {
    final recording = SilentRecording(format, chunk);
    started.add(recording);
    recording._start();
    return recording;
  }

  @override
  Future<void> dispose() async {}
}

/// The [Recording] returned by [SilentBackend]: a timer that emits zeroed PCM.
class SilentRecording implements Recording {
  SilentRecording(this._format, this._chunk);

  final CaptureFormat _format;
  final Duration _chunk;
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();

  Timer? _timer;
  RecordingState _state = RecordingState.idle;

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
    final frames = _pcm.length ~/ _format.bytesPerFrame;
    return Duration(
      microseconds:
          frames * Duration.microsecondsPerSecond ~/ _format.sampleRate,
    );
  }

  void _start() {
    _state = RecordingState.recording;
    _timer = Timer.periodic(_chunk, (_) => _emit());
  }

  void _emit() {
    if (_state != RecordingState.recording) return;
    final bytes =
        _format.bytesPerSecond *
        _chunk.inMicroseconds ~/
        Duration.microsecondsPerSecond;
    // Round down to a whole frame so the PCM is always frame-aligned.
    final aligned = (bytes ~/ _format.bytesPerFrame) * _format.bytesPerFrame;
    final silence = Uint8List(aligned);
    _pcm.add(silence);
    if (!_frames.isClosed) _frames.add(silence);
  }

  @override
  Future<void> pause() async {
    if (_state == RecordingState.recording) {
      _timer?.cancel();
      _timer = null;
      _state = RecordingState.paused;
    }
  }

  @override
  Future<void> resume() async {
    if (_state == RecordingState.paused) {
      _state = RecordingState.recording;
      _timer = Timer.periodic(_chunk, (_) => _emit());
    }
  }

  @override
  Future<Uint8List> stop() async {
    if (_state != RecordingState.disposed) {
      _timer?.cancel();
      _timer = null;
      _state = RecordingState.stopped;
    }
    if (!_frames.isClosed) await _frames.close();
    return wavFromPcm(_pcm.toBytes(), _format);
  }

  @override
  Future<String> stopToFile(String path) async {
    final wav = await stop();
    await writeBytes(path, wav);
    return path;
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    _state = RecordingState.disposed;
    if (!_frames.isClosed) await _frames.close();
  }
}
