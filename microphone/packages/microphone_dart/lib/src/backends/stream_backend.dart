import 'dart:async';
import 'dart:typed_data';

import '../capture_backend.dart';
import '../capture_device.dart';
import '../capture_format.dart';
import '../file_writer.dart';
import '../recording.dart';
import '../wav.dart';
import 'sample_aligner.dart';

/// A capture backend fed by an external stream of PCM frames.
///
/// Instead of a microphone, this presents an injected [Stream] of interleaved
/// S16LE samples (the same shape [Recording.frames] delivers) as a capture
/// source. It lets any PCM producer -- a decoded clip, a synthesized tone, a
/// network feed -- be consumed through the ordinary [Recording] API, and is the
/// building block soundboard uses to feed mixed clip audio back into a
/// microphone pipeline.
///
/// The injected [source] dictates the real [CaptureFormat]; the format passed
/// to [startRecording] is advisory and ignored in favor of [format]. The source
/// is expected to be single-subscription and is listened to once, so one
/// recording is produced per backend.
class StreamCaptureBackend extends CaptureBackend {
  StreamCaptureBackend({
    required Stream<Uint8List> source,
    this.format = const CaptureFormat(),
    this.name = 'stream',
    this.priority = 50,
  }) : _source = source;

  final Stream<Uint8List> _source;

  /// The format the injected [source] frames are in.
  final CaptureFormat format;

  @override
  final String name;

  @override
  final int priority;

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<CaptureDevice>> devices() async => const [
    CaptureDevice(id: 'stream', label: 'Injected PCM stream', isDefault: true),
  ];

  @override
  Future<Recording> startRecording({
    CaptureFormat format = const CaptureFormat(),
    String? deviceId,
    bool retainPcm = true,
  }) async => StreamRecording(_source, this.format, retainPcm: retainPcm);

  @override
  Future<void> dispose() async {}
}

/// The [Recording] returned by [StreamCaptureBackend].
///
/// Subscribes to the injected source and republishes each chunk on [frames]
/// while accumulating it for [stop]. Audio arriving while paused is dropped, so
/// the paused interval leaves no gap.
class StreamRecording implements Recording {
  StreamRecording(
    Stream<Uint8List> source,
    this._format, {
    bool retainPcm = true,
  }) : _retainPcm = retainPcm {
    _state = RecordingState.recording;
    _sub = source.listen(_onData, onError: _onError, onDone: _onDone);
  }

  final CaptureFormat _format;
  final bool _retainPcm;
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  int _pcmBytes = 0;
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();

  final SampleAligner _aligner = SampleAligner();
  StreamSubscription<Uint8List>? _sub;
  RecordingState _state = RecordingState.idle;
  Uint8List? _finalWav;

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
    final frameCount = _pcmBytes ~/ _format.bytesPerFrame;
    return Duration(
      microseconds:
          frameCount * Duration.microsecondsPerSecond ~/ _format.sampleRate,
    );
  }

  void _onData(Uint8List chunk) {
    // Align before the pause check, so dropping a chunk cannot shift the
    // samples after it.
    final samples = _aligner.align(chunk);
    if (_state != RecordingState.recording) return; // dropped while paused
    if (samples.isEmpty) return;
    _pcmBytes += samples.length;
    if (_retainPcm) _pcm.add(samples);
    if (!_frames.isClosed) _frames.add(samples);
  }

  void _onError(Object error, StackTrace stack) {
    if (!_frames.isClosed) _frames.addError(error, stack);
  }

  void _onDone() {
    // The source ended on its own; finish the recording so consumers of
    // [frames] and [stop] see a clean close.
    if (_state == RecordingState.recording || _state == RecordingState.paused) {
      _state = RecordingState.stopped;
    }
    if (!_frames.isClosed) _frames.close();
  }

  @override
  Future<void> pause() async {
    if (_state == RecordingState.recording) _state = RecordingState.paused;
  }

  @override
  Future<void> resume() async {
    if (_state == RecordingState.paused) _state = RecordingState.recording;
  }

  @override
  Future<Uint8List> stop() async {
    if (_finalWav != null) return _finalWav!;
    if (_state != RecordingState.disposed) _state = RecordingState.stopped;
    await _sub?.cancel();
    _sub = null;
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
    await _sub?.cancel();
    _sub = null;
    _state = RecordingState.disposed;
    if (!_frames.isClosed) await _frames.close();
  }
}
