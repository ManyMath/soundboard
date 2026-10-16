import 'dart:async';
import 'dart:typed_data';

import '../capture_backend.dart';
import '../capture_device.dart';
import '../capture_format.dart';
import '../file_writer.dart';
import '../recording.dart';
import '../wav.dart';
import 'sample_aligner.dart';

/// A capture backend that sums several capture sources into one stream.
///
/// Each source is an ordinary [CaptureBackend]; on [startRecording] this starts
/// a recording on every source and mixes their [Recording.frames] sample for
/// sample, clamping the sum to the 16-bit range. The result is a single
/// [Recording] whose [Recording.frames] -- and therefore the level metering in
/// `AudioLevel.fromPcm` / `RecordingLevels.levels` -- reflect the blend.
///
/// Mixing is clocked by one source, the [primary] (the first source by
/// default). Each chunk the primary delivers becomes one mixed output chunk;
/// the other sources are buffered and drawn from to match, contributing silence
/// when they have nothing queued. This keeps the output flowing at the primary's
/// cadence and never stalls waiting on an idle source -- which is exactly what a
/// soundboard needs, where the microphone runs continuously (the primary) and
/// clips come and go. The output ends when the primary ends.
///
/// All sources are expected to share the mix [format] (sample rate, channels,
/// S16LE). The format passed to [startRecording] is advisory and ignored in
/// favor of [format].
class MixingCaptureBackend extends CaptureBackend {
  MixingCaptureBackend(
    List<CaptureBackend> sources, {
    this.format = const CaptureFormat(),
    this.name = 'mixing',
    this.priority = 60,
    int primary = 0,
    this.ownsSources = true,
  }) : assert(sources.isNotEmpty, 'at least one source is required'),
       assert(
         primary >= 0 && primary < sources.length,
         'primary index out of range',
       ),
       _sources = List.unmodifiable(sources),
       _primary = primary;

  final List<CaptureBackend> _sources;
  final int _primary;

  /// Whether [dispose] disposes the sources too. Pass false when the sources
  /// are shared (e.g. the globally registered hardware backend) and owned by
  /// someone else.
  final bool ownsSources;

  /// The format the mixed output is produced in. All sources must match it.
  final CaptureFormat format;

  @override
  final String name;

  @override
  final int priority;

  /// The sources being mixed, in order.
  List<CaptureBackend> get sources => _sources;

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {
    for (final s in _sources) {
      await s.initialize();
    }
  }

  @override
  Future<bool> hasPermission() async {
    for (final s in _sources) {
      if (!await s.hasPermission()) return false;
    }
    return true;
  }

  @override
  Future<bool> requestPermission() async {
    var granted = true;
    for (final s in _sources) {
      if (!await s.requestPermission()) granted = false;
    }
    return granted;
  }

  @override
  Future<List<CaptureDevice>> devices() async => const [
    CaptureDevice(id: 'mixing', label: 'Mixed sources', isDefault: true),
  ];

  @override
  Future<Recording> startRecording({
    CaptureFormat format = const CaptureFormat(),
    String? deviceId,
    bool retainPcm = true,
  }) async {
    final children = <Recording>[];
    try {
      for (var i = 0; i < _sources.length; i++) {
        final s = _sources[i];
        await s.initialize();
        // The children only feed the mix through their frames; their own
        // accumulated PCM is never read, so never retain it. [deviceId] selects
        // the input of the primary (the microphone), where it is meaningful.
        children.add(
          await s.startRecording(
            format: this.format,
            deviceId: i == _primary ? deviceId : null,
            retainPcm: false,
          ),
        );
      }
    } catch (_) {
      // Nothing else holds the children that did start (typically the live
      // microphone), so shut them down before reporting the failure.
      for (final c in children) {
        try {
          await c.dispose();
        } on Object {
          // Keep the original error.
        }
      }
      rethrow;
    }
    return MixingRecording(
      children,
      this.format,
      _primary,
      retainPcm: retainPcm,
    );
  }

  @override
  Future<void> dispose() async {
    if (!ownsSources) return;
    for (final s in _sources) {
      await s.dispose();
    }
  }
}

/// The [Recording] returned by [MixingCaptureBackend].
class MixingRecording implements Recording {
  MixingRecording(
    this._children,
    this._format,
    this._primary, {
    bool retainPcm = true,
  }) : _retainPcm = retainPcm {
    _state = RecordingState.recording;
    for (var i = 0; i < _children.length; i++) {
      _buffers.add(BytesBuilder(copy: false));
      final index = i;
      _subs.add(
        _children[i].frames.listen(
          (chunk) => _onData(index, chunk),
          onDone: () => _onDone(index),
          onError: _onError,
        ),
      );
    }
  }

  static final Uint8List _empty = Uint8List(0);

  final List<Recording> _children;
  final CaptureFormat _format;
  final int _primary;
  final bool _retainPcm;

  final SampleAligner _primaryAligner = SampleAligner();
  final List<BytesBuilder> _buffers = [];
  final List<StreamSubscription<Uint8List>> _subs = [];
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  int _pcmBytes = 0;
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();

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

  void _onData(int i, Uint8List chunk) {
    if (_state == RecordingState.disposed) return;
    if (i == _primary) {
      // Align before the pause check, so dropping a chunk cannot shift the
      // samples after it.
      final samples = _primaryAligner.align(chunk);
      if (_state != RecordingState.recording) return; // dropped while paused
      _emit(samples);
    } else {
      _buffers[i].add(chunk);
    }
  }

  /// Mixes one primary [primaryChunk] with matching bytes drawn from each other
  /// source's buffer, clamps, and publishes the result.
  void _emit(Uint8List primaryChunk) {
    final frameSamples = primaryChunk.length >> 1;
    if (frameSamples == 0) return;
    final acc = Int32List(frameSamples);
    _accumulate(acc, primaryChunk);
    for (var j = 0; j < _buffers.length; j++) {
      if (j == _primary) continue;
      _accumulate(acc, _takeFront(_buffers[j], primaryChunk.length));
    }
    final out = Uint8List(primaryChunk.length);
    final view = ByteData.sublistView(out);
    for (var i = 0; i < frameSamples; i++) {
      var v = acc[i];
      if (v > 32767) {
        v = 32767;
      } else if (v < -32768) {
        v = -32768;
      }
      view.setInt16(i << 1, v, Endian.little);
    }
    _pcmBytes += out.length;
    if (_retainPcm) _pcm.add(out);
    if (!_frames.isClosed) _frames.add(out);
  }

  /// Adds the S16LE samples in [bytes] into [acc] (truncated to acc's length).
  static void _accumulate(Int32List acc, Uint8List bytes) {
    final samples = bytes.length >> 1;
    final n = samples < acc.length ? samples : acc.length;
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < n; i++) {
      acc[i] += view.getInt16(i << 1, Endian.little);
    }
  }

  /// Removes and returns up to [n] bytes of whole samples from the front of
  /// [bb], keeping the remainder buffered for the next chunk.
  static Uint8List _takeFront(BytesBuilder bb, int n) {
    if (bb.isEmpty) return _empty;
    final all = bb.toBytes();
    bb.clear();
    // Never split a sample: a trailing odd byte waits for its other half.
    final take = (n < all.length ? n : all.length) & ~1;
    if (take == all.length) return all;
    bb.add(Uint8List.sublistView(all, take));
    return Uint8List.sublistView(all, 0, take);
  }

  void _onError(Object error, StackTrace stack) {
    if (!_frames.isClosed) _frames.addError(error, stack);
  }

  void _onDone(int i) {
    // The output is the primary's timeline, so it ends when the primary does.
    if (i == _primary) _finish();
  }

  void _finish() {
    if (_state == RecordingState.recording || _state == RecordingState.paused) {
      _state = RecordingState.stopped;
    }
    if (!_frames.isClosed) _frames.close();
  }

  @override
  Future<void> pause() async {
    if (_state == RecordingState.recording) {
      _state = RecordingState.paused;
      for (final c in _children) {
        await c.pause();
      }
    }
  }

  @override
  Future<void> resume() async {
    if (_state == RecordingState.paused) {
      _state = RecordingState.recording;
      for (final c in _children) {
        await c.resume();
      }
    }
  }

  @override
  Future<Uint8List> stop() async {
    if (_finalWav != null) return _finalWav!;
    // Stop the children while still subscribed: a child's stop() can deliver
    // a last chunk (the FFI backend's final drain), which still belongs in the
    // mix.
    for (final c in _children) {
      try {
        await c.stop();
      } on Object {
        // A child that fails to stop should not block the others.
      }
    }
    if (_state != RecordingState.disposed) _state = RecordingState.stopped;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
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
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final c in _children) {
      await c.dispose();
    }
    _state = RecordingState.disposed;
    if (!_frames.isClosed) await _frames.close();
  }
}
