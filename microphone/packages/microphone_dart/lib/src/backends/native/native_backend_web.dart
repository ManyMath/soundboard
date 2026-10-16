import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
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
/// getUserMedia provides the input stream (and drives the permission prompt); an
/// AudioWorklet converts it to S16LE off the main thread (a ScriptProcessorNode
/// stands in where AudioWorklet is unavailable). The browser picks the sample
/// rate (usually 48 kHz); [Recording.format] reports what is in effect. File
/// output is unsupported on the web -- use the WAV bytes from [Recording.stop].
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
    bool retainPcm = true,
  }) async {
    final web.MediaStream stream;
    try {
      stream = await _getUserMedia(deviceId);
    } on Object catch (e) {
      throw _captureError(e);
    }
    try {
      return await WebRecording._open(stream, retainPcm: retainPcm);
    } on Object catch (e) {
      // The device is already open; nothing else will release it.
      for (final track in _tracks(stream)) {
        track.stop();
      }
      throw CaptureException('Web Audio setup failed: $e');
    }
  }

  /// Maps a getUserMedia failure to the matching package exception: only a
  /// refusal is a [PermissionDeniedException]; a missing, busy or unknown
  /// device is a [CaptureException].
  static MicrophoneException _captureError(Object error) {
    if (!web.window.isSecureContext) {
      return const CaptureException(
        'Microphone capture needs a secure context (HTTPS or localhost).',
      );
    }
    String? name;
    try {
      final o = error as JSObject;
      if (o.isA<web.DOMException>()) name = (o as web.DOMException).name;
    } on Object {
      // A Dart error (e.g. NullRejectionException), not a DOMException.
    }
    return switch (name) {
      'NotAllowedError' || 'SecurityError' => PermissionDeniedException(
        'Microphone access was denied: $error',
      ),
      _ => CaptureException('getUserMedia failed: $error'),
    };
  }

  @override
  Future<void> dispose() async {}

  static Future<web.MediaStream> _getUserMedia(String? deviceId) async {
    final devices = web.window.navigator.mediaDevices;
    // Pin a specific input when asked; otherwise accept the default. A bare
    // deviceId is only an "ideal" constraint, which lets the browser fall back
    // to another input when that one is gone, so require it exactly.
    final JSAny audio = deviceId == null || deviceId.isEmpty
        ? true.toJS
        : web.MediaTrackConstraints(
            deviceId: web.ConstrainDOMStringParameters(exact: deviceId.toJS),
          );
    final constraints = web.MediaStreamConstraints(audio: audio);
    return devices.getUserMedia(constraints).toDart;
  }

  static List<web.MediaStreamTrack> _tracks(web.MediaStream stream) {
    final tracks = stream.getTracks().toDart;
    return tracks.cast<web.MediaStreamTrack>();
  }
}

// The AudioWorklet processor, loaded from a Blob URL. Its input is downmixed
// to mono (the node's channelCount); it converts to Int16 on the audio thread
// and posts ~20 ms batches as {gen, pcm}. "reset" drops its partial batch and
// takes a new generation (sent on resume, so audio from the paused interval is
// never delivered); "flush" posts the partial batch, then {flushed: true}.
const _workletSource = '''
class MicrophoneCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.frames = Math.max(128, Math.round(sampleRate / 50));
    this.chunk = new Int16Array(this.frames);
    this.length = 0;
    this.gen = 0;
    this.port.onmessage = (e) => {
      if (e.data.cmd === 'reset') {
        this.length = 0;
        this.gen = e.data.gen;
      } else if (e.data.cmd === 'flush') {
        this.post();
        this.port.postMessage({flushed: true});
      }
    };
  }
  post() {
    if (this.length === 0) return;
    const pcm = this.chunk.slice(0, this.length).buffer;
    this.port.postMessage({gen: this.gen, pcm}, [pcm]);
    this.length = 0;
  }
  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (channel) {
      for (let i = 0; i < channel.length; i++) {
        const s = Math.max(-1, Math.min(1, channel[i]));
        this.chunk[this.length++] = Math.round(s * 32767);
        if (this.length === this.frames) this.post();
      }
    }
    return true;
  }
}
registerProcessor('microphone-capture', MicrophoneCapture);
''';

/// A single browser recording.
class WebRecording implements Recording {
  WebRecording._(this._stream, this._context, {required bool retainPcm})
    : _retainPcm = retainPcm,
      _format = CaptureFormat(
        sampleRate: _context.sampleRate.round(),
        channels: 1,
      );

  /// Builds the Web Audio graph for [stream], closing the context again if
  /// any of it fails.
  static Future<WebRecording> _open(
    web.MediaStream stream, {
    required bool retainPcm,
  }) async {
    final context = web.AudioContext();
    final recording = WebRecording._(stream, context, retainPcm: retainPcm);
    try {
      await recording._connect();
    } on Object {
      context.close().toDart.ignore();
      rethrow;
    }
    return recording;
  }

  final web.MediaStream _stream;
  final web.AudioContext _context;
  final CaptureFormat _format;
  web.MediaStreamAudioSourceNode? _source;
  // Exactly one of these delivers the audio.
  web.AudioWorkletNode? _worklet;
  web.ScriptProcessorNode? _processor;

  // Bumped on every resume; worklet batches from an older generation hold
  // audio from before the pause and are dropped.
  int _generation = 0;
  Completer<void>? _flushed;

  final bool _retainPcm;
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  int _pcmBytes = 0;
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  RecordingState _state = RecordingState.idle;
  Future<Uint8List>? _stopped;
  bool _tornDown = false;

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

  Future<void> _connect() async {
    final source = _source = _context.createMediaStreamSource(_stream);
    final web.AudioNode capture = await _workletNode() ?? _scriptProcessor();
    source.connect(capture);
    // The capture node's output stays silent (it never writes it), so
    // connecting to destination -- which some browsers need before they run
    // the node -- does not echo the mic.
    capture.connect(_context.destination);
    // The browser ends a track itself when the input is unplugged or access
    // is revoked; without this the recording would just go quiet.
    for (final track in WebCaptureBackend._tracks(_stream)) {
      track.onended = _onTrackEnded.toJS;
    }
    _state = RecordingState.recording;
  }

  /// The AudioWorklet capture node, or null where AudioWorklet is missing
  /// (older browsers) or its module cannot load (e.g. a CSP without blob:).
  Future<web.AudioWorkletNode?> _workletNode() async {
    if (!_context.has('audioWorklet')) return null;
    final url = web.URL.createObjectURL(
      web.Blob(
        <web.BlobPart>[_workletSource.toJS].toJS,
        web.BlobPropertyBag(type: 'text/javascript'),
      ),
    );
    try {
      await _context.audioWorklet.addModule(url).toDart;
    } on Object {
      return null;
    } finally {
      web.URL.revokeObjectURL(url);
    }
    final node = web.AudioWorkletNode(
      _context,
      'microphone-capture',
      web.AudioWorkletNodeOptions(
        numberOfInputs: 1,
        numberOfOutputs: 1,
        outputChannelCount: <JSNumber>[1.toJS].toJS,
        channelCount: 1,
        channelCountMode: 'explicit',
      ),
    );
    node.port.onmessage = _onWorkletMessage.toJS;
    return _worklet = node;
  }

  web.ScriptProcessorNode _scriptProcessor() {
    // 4096-frame buffer, mono in/out.
    final node = _context.createScriptProcessor(4096, 1, 1);
    node.onaudioprocess = _onAudio.toJS;
    return _processor = node;
  }

  void _onWorkletMessage(web.MessageEvent event) {
    final data = event.data as JSObject;
    if (data.has('flushed')) {
      _flushed?.complete();
      return;
    }
    if ((data['gen'] as JSNumber).toDartInt != _generation) return;
    _deliver((data['pcm'] as JSArrayBuffer).toDart.asUint8List());
  }

  /// The ScriptProcessor fallback hands us Float32 samples; convert to S16LE.
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
    _deliver(out);
  }

  void _deliver(Uint8List chunk) {
    if (_state != RecordingState.recording) return; // dropped while paused
    _pcmBytes += chunk.length;
    if (_retainPcm) _pcm.add(chunk);
    if (!_frames.isClosed) _frames.add(chunk);
  }

  void _onTrackEnded(web.Event _) {
    if (_state != RecordingState.recording && _state != RecordingState.paused) {
      return;
    }
    _teardown();
    _state = RecordingState.stopped;
    if (!_frames.isClosed) {
      _frames.addError(
        const CaptureException(
          'The microphone track ended (input removed or access revoked).',
        ),
      );
      _frames.close();
    }
  }

  @override
  Future<void> pause() async {
    if (_state == RecordingState.recording) {
      // Keep what the worklet captured up to now; batches arriving later
      // are dropped.
      await _flushWorklet();
      if (_state == RecordingState.recording) _state = RecordingState.paused;
    }
  }

  @override
  Future<void> resume() async {
    if (_state == RecordingState.paused) {
      _generation++;
      _worklet?.port.postMessage(
        <String, Object>{'cmd': 'reset', 'gen': _generation}.jsify(),
      );
      _state = RecordingState.recording;
    }
  }

  @override
  Future<Uint8List> stop() => _stopped ??= _stop();

  Future<Uint8List> _stop() async {
    if (_state != RecordingState.disposed) {
      if (_state == RecordingState.recording) await _flushWorklet();
      _teardown();
      _state = RecordingState.stopped;
    }
    if (!_frames.isClosed) await _frames.close();
    return wavFromPcm(_pcm.toBytes(), _format);
  }

  /// Collects the worklet's partial batch (up to ~20 ms), before a pause or
  /// teardown.
  Future<void> _flushWorklet() async {
    final node = _worklet;
    if (node == null || _tornDown) return;
    final flushed = _flushed = Completer<void>();
    node.port.postMessage(<String, Object>{'cmd': 'flush'}.jsify());
    // A suspended context never runs the worklet, so do not wait forever.
    await flushed.future.timeout(
      const Duration(milliseconds: 200),
      onTimeout: () {},
    );
    _flushed = null;
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
    // stop() then dispose() both get here; closing an already-closed context
    // rejects, so only tear down once.
    if (_tornDown) return;
    _tornDown = true;
    try {
      _worklet?.port.onmessage = null;
      _processor?.onaudioprocess = null;
      _source?.disconnect();
      _worklet?.disconnect();
      _processor?.disconnect();
      for (final track in WebCaptureBackend._tracks(_stream)) {
        track.onended = null;
        track.stop();
      }
      // Best-effort: a rejection here has nothing left to clean up.
      _context.close().toDart.ignore();
    } on Object {
      // Best-effort cleanup; the recording is already final.
    }
  }

  @override
  Future<void> dispose() async {
    _teardown();
    _state = RecordingState.disposed;
    if (!_frames.isClosed) await _frames.close();
  }
}
