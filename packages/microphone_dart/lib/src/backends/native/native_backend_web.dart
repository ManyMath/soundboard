import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../capture_backend.dart';
import '../../capture_device.dart';
import '../../capture_format.dart';
import '../../exceptions.dart';
import '../../recording.dart';
import '../../wav.dart';

/// On the web the default backend captures via getUserMedia + Web Audio.
CaptureBackend? createNativeBackend() => WebCaptureBackend();

/// Captures microphone audio in the browser.
///
/// getUserMedia provides the input stream (and drives the permission prompt); a
/// ScriptProcessorNode delivers Float32 PCM, which we downconvert to S16LE. The
/// browser picks the sample rate (usually 48 kHz); [Recording.format] reports
/// what is actually in effect. File output is unsupported on the web -- use the
/// WAV bytes from [Recording.stop].
class WebCaptureBackend extends CaptureBackend {
  @override
  String get name => 'web';

  @override
  int get priority => 100;

  // getUserMedia exists in every browser we target; an insecure context (no
  // HTTPS/localhost) leaves mediaDevices null, which we surface at capture time.
  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasPermission() async {
    // The Permissions API can report mic state without prompting, but support
    // is uneven (Safari lacks the 'microphone' name). Treat unknown as "ask".
    return false;
  }

  @override
  Future<bool> requestPermission() async {
    try {
      final stream = await _getUserMedia(null);
      // Granting is enough; stop the probe stream so we do not hold the device.
      for (final track in _tracks(stream)) {
        track.stop();
      }
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<List<CaptureDevice>> devices() async {
    try {
      final infos =
          (await web.window.navigator.mediaDevices.enumerateDevices().toDart)
              .toDart;
      final out = <CaptureDevice>[];
      for (final info in infos) {
        if (info.kind != 'audioinput') continue;
        // Browsers hide labels until permission is granted; "default" is the
        // well-known id for the system default input.
        out.add(
          CaptureDevice(
            id: info.deviceId,
            label: info.label.isEmpty ? 'Microphone' : info.label,
            isDefault: info.deviceId == 'default',
          ),
        );
      }
      return out;
    } on Object {
      return const [];
    }
  }

  @override
  Future<Recording> startRecording({
    CaptureFormat format = const CaptureFormat(),
    String? deviceId,
  }) async {
    final web.MediaStream stream;
    try {
      stream = await _getUserMedia(deviceId);
    } on Object catch (e) {
      throw PermissionDeniedException(
        'getUserMedia failed (permission denied or no microphone): $e',
      );
    }
    return WebRecording._(stream);
  }

  @override
  Future<void> dispose() async {}

  static Future<web.MediaStream> _getUserMedia(String? deviceId) async {
    final devices = web.window.navigator.mediaDevices;
    // Pin a specific input when asked; otherwise accept the default.
    final JSAny audio = deviceId == null
        ? true.toJS
        : web.MediaTrackConstraints(deviceId: deviceId.toJS);
    final constraints = web.MediaStreamConstraints(audio: audio);
    return devices.getUserMedia(constraints).toDart;
  }

  static List<web.MediaStreamTrack> _tracks(web.MediaStream stream) {
    final tracks = stream.getTracks().toDart;
    return tracks.cast<web.MediaStreamTrack>();
  }
}

/// A single browser recording driven by a ScriptProcessorNode.
class WebRecording implements Recording {
  WebRecording._(this._stream) {
    _context = web.AudioContext();
    final rate = _context.sampleRate.round();
    _format = CaptureFormat(sampleRate: rate, channels: 1);
    _source = _context.createMediaStreamSource(_stream);
    // 4096-frame buffer, mono in/out. Output stays silent (we never fill it),
    // so connecting to destination -- required for onaudioprocess to fire in
    // some browsers -- does not echo the mic.
    _processor = _context.createScriptProcessor(4096, 1, 1);
    _processor.onaudioprocess = _onAudio.toJS;
    _source.connect(_processor);
    _processor.connect(_context.destination);
    _state = RecordingState.recording;
  }

  final web.MediaStream _stream;
  late final web.AudioContext _context;
  late final web.MediaStreamAudioSourceNode _source;
  late final web.ScriptProcessorNode _processor;
  late final CaptureFormat _format;

  final BytesBuilder _pcm = BytesBuilder(copy: false);
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
    final frameCount = _pcm.length ~/ _format.bytesPerFrame;
    return Duration(
      microseconds:
          frameCount * Duration.microsecondsPerSecond ~/ _format.sampleRate,
    );
  }

  /// Web Audio hands us a buffer of Float32 samples; convert to S16LE.
  void _onAudio(web.AudioProcessingEvent event) {
    if (_state != RecordingState.recording) return;
    final input = event.inputBuffer.getChannelData(0).toDart;
    final out = Uint8List(input.length * 2);
    final view = ByteData.sublistView(out);
    for (var i = 0; i < input.length; i++) {
      // Clamp to [-1, 1], scale to full-scale 16-bit.
      var s = input[i];
      if (s > 1) s = 1;
      if (s < -1) s = -1;
      view.setInt16(i * 2, (s * 32767).round(), Endian.little);
    }
    _pcm.add(out);
    if (!_frames.isClosed) _frames.add(out);
  }

  @override
  Future<void> pause() async {
    if (_state == RecordingState.recording) {
      _state = RecordingState.paused;
    }
  }

  @override
  Future<void> resume() async {
    if (_state == RecordingState.paused) {
      _state = RecordingState.recording;
    }
  }

  @override
  Future<Uint8List> stop() async {
    if (_finalWav != null) return _finalWav!;
    if (_state != RecordingState.disposed) {
      _teardown();
      _state = RecordingState.stopped;
    }
    if (!_frames.isClosed) await _frames.close();
    return _finalWav = wavFromPcm(_pcm.toBytes(), _format);
  }

  @override
  Future<String> stopToFile(String path) async {
    await stop();
    throw UnsupportedError(
      'Writing to a file is not supported on the web; use Recording.stop to get '
      'the WAV bytes and save them yourself (e.g. via a download).',
    );
  }

  void _teardown() {
    try {
      _processor.onaudioprocess = null;
      _source.disconnect();
      _processor.disconnect();
      for (final track in WebCaptureBackend._tracks(_stream)) {
        track.stop();
      }
      _context.close();
    } on Object {
      // Best-effort cleanup; the recording is already final.
    }
  }

  @override
  Future<void> dispose() async {
    if (_state != RecordingState.disposed) {
      _teardown();
    }
    _state = RecordingState.disposed;
    if (!_frames.isClosed) await _frames.close();
  }
}
