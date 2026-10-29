import 'dart:async';
import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart';
import 'package:mixer_dart/mixer_dart.dart';
import 'package:sound_dart/sound_dart.dart';

import 'clip.dart';

/// A destination for a triggered soundboard voice.
enum SoundboardOutput {
  /// Play through the active `sound_dart` speaker backend.
  speakers,

  /// Add the clip to [Soundboard.mixedFrames] and virtual-microphone capture.
  microphone,
}

/// Routes sound clips to speakers, a microphone mix, or both.
///
/// The package remains pure Dart. `sound_dart` supplies decoding and ordinary
/// speaker playback, `mixer_dart` supplies the device-independent PCM graph,
/// and `microphone_dart` supplies physical capture and capture-stream mixing.
class Soundboard {
  Soundboard({
    this.format = const CaptureFormat(),
    Duration chunk = const Duration(milliseconds: 20),
    Set<SoundboardOutput> defaultOutputs = const {
      SoundboardOutput.speakers,
      SoundboardOutput.microphone,
    },
  }) : defaultOutputs = Set<SoundboardOutput>.unmodifiable(defaultOutputs),
       _mixer = PcmMixer(
         format: PcmFormat(
           sampleRate: format.sampleRate,
           channels: format.channels,
         ),
         chunk: chunk,
       );

  /// Format of [mixedFrames] and [asMicrophoneBackend].
  final CaptureFormat format;

  /// Destinations used by [play] when no explicit [outputs] are provided.
  final Set<SoundboardOutput> defaultOutputs;

  final PcmMixer _mixer;
  final Set<SoundboardVoice> _voices = <SoundboardVoice>{};
  bool _disposed = false;
  int _stopGeneration = 0;
  double _masterVolume = 1;

  /// Linear gain applied to all soundboard clips on every destination.
  double get masterVolume => _masterVolume;
  set masterVolume(double value) {
    if (!value.isFinite || value < 0) {
      throw ArgumentError.value(value, 'value', 'must be finite and >= 0');
    }
    _masterVolume = value;
    _mixer.masterGain = value;
    for (final voice in _voices) {
      unawaited(voice._applySpeakerVolume());
    }
  }

  double _micVolume = 1;

  /// Linear gain applied to the physical microphone bus.
  double get micVolume => _micVolume;
  set micVolume(double value) {
    if (!value.isFinite || value < 0) {
      throw ArgumentError.value(value, 'value', 'must be finite and >= 0');
    }
    _micVolume = value;
  }

  /// The mixed clip bus, as interleaved S16LE frames in [format].
  ///
  /// It runs on a timer, except while a recording from [asMicrophoneBackend]
  /// is capturing: the microphone's clock drives it then, and the chunks
  /// arrive at that pace and in the microphone's chunk sizes.
  Stream<Uint8List> get mixedFrames => _mixer.frames;

  /// Loads and decodes any `sound_dart` [SoundSource].
  Future<Clip> load(SoundSource source) async {
    final stream = await Sound.openPcmStream(source);
    try {
      // Without a decoding PCM tap (no native library, or the web) sound_dart
      // falls back to the silent backend, which yields zero frames.
      if (stream.frameCount == 0) {
        throw const UnsupportedSourceException(
          'decoded no audio: the source is empty or no decoding sound '
          'backend is available',
        );
      }
      return Clip(
        samples: stream.buffer,
        sampleRate: stream.sampleRate,
        channels: stream.channels,
      );
    } finally {
      await stream.dispose();
    }
  }

  /// Loads and decodes an audio file.
  Future<Clip> loadFile(String path) => load(SoundSource.file(path));

  /// Loads raw interleaved S16LE [bytes] described by [format].
  Clip loadBytes(Uint8List bytes, {required CaptureFormat format}) =>
      Clip.fromPcm(bytes, format);

  /// Starts an independently controllable voice.
  ///
  /// By default the clip is heard locally and added to the microphone bus.
  /// Pass an explicit [outputs] set to select only one route. The microphone
  /// route is sample-rate converted and channel-adapted by `mixer_dart`.
  Future<SoundboardVoice> play(
    Clip clip, {
    double gain = 1,
    bool looping = false,
    Set<SoundboardOutput>? outputs,
  }) async {
    if (_disposed) return SoundboardVoice._inactive(this, clip);
    if (!gain.isFinite || gain < 0) {
      throw ArgumentError.value(gain, 'gain', 'must be finite and >= 0');
    }
    final routes = Set<SoundboardOutput>.unmodifiable(
      outputs ?? defaultOutputs,
    );
    if (routes.isEmpty) {
      throw ArgumentError.value(outputs, 'outputs', 'must not be empty');
    }

    final generation = _stopGeneration;
    final masterAtStart = _masterVolume;
    MixerVoice? mixerVoice;
    Playback? speakerPlayback;
    try {
      if (routes.contains(SoundboardOutput.microphone)) {
        mixerVoice = _mixer.play(clip.pcmClip, gain: gain, looping: looping);
      }
      if (routes.contains(SoundboardOutput.speakers)) {
        final wav = wavFromPcm(clip.pcmClip.toBytes(), clip.format);
        speakerPlayback = await Sound.playBytes(
          wav,
          format: 'wav',
          volume: gain * _masterVolume,
          loop: looping,
        );
      }
    } catch (_) {
      mixerVoice?.stop();
      rethrow;
    }

    // dispose() or stopAll() ran while the speaker route was starting.
    if (_disposed || generation != _stopGeneration) {
      mixerVoice?.stop();
      await speakerPlayback?.dispose();
      return SoundboardVoice._inactive(this, clip);
    }

    final voice = SoundboardVoice._(
      this,
      clip,
      mixerVoice: mixerVoice,
      speakerPlayback: speakerPlayback,
      gain: gain,
      looping: looping,
    );
    _voices.add(voice);
    // Route errors belong to whoever awaits voice.onComplete, not the zone.
    voice.onComplete.whenComplete(() => _voices.remove(voice)).ignore();
    if (speakerPlayback != null && _masterVolume != masterAtStart) {
      await voice._applySpeakerVolume();
    }
    return voice;
  }

  /// Stops every active voice. The physical microphone is unaffected.
  Future<void> stopAll() async {
    _stopGeneration++;
    final voices = List<SoundboardVoice>.of(_voices);
    _mixer.stopAll();
    await Future.wait(voices.map((voice) => voice.stop()));
    // Voices started while awaiting the stops are not ours to drop.
    _voices.removeAll(voices);
  }

  /// A capture backend yielding the physical microphone plus [mixedFrames].
  ///
  /// The clip bus follows the microphone's clock while a recording runs:
  /// every captured chunk advances the clips by exactly its own length, so a
  /// long session neither builds latency nor drops clip audio when the device
  /// clock and the system timer disagree.
  ///
  /// Resolve [physicalMic] before registering the result as the active global
  /// backend, or the soundboard would feed itself. For an open-ended session,
  /// use `retainPcm: false` when starting the returned backend.
  /// [audioSessionManagement] applies to the physical microphone. On iOS,
  /// application mode leaves category, activation, routing and interruptions
  /// to the application coordinating both playback and capture.
  CaptureBackend asMicrophoneBackend({
    CaptureBackend? physicalMic,
    AudioSessionManagement audioSessionManagement =
        AudioSessionManagement.automatic,
  }) {
    // A mixing backend with one source supplies the Recording plumbing
    // (retained PCM, WAV output, pause state) around the board's microphone.
    return MixingCaptureBackend(
      <CaptureBackend>[
        _BoardMicBackend(
          this,
          physicalMic ?? Microphone.backend,
          audioSessionManagement,
        ),
      ],
      format: format,
      ownsSources: false,
    );
  }

  /// Stops all voices and releases the mixer.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final voices = List<SoundboardVoice>.of(_voices);
    try {
      await Future.wait(voices.map((voice) => voice.dispose()));
    } finally {
      _voices.clear();
      await _mixer.dispose();
    }
  }
}

/// A single routed soundboard trigger with controls shared by both outputs.
final class SoundboardVoice {
  SoundboardVoice._(
    this._board,
    this.clip, {
    required MixerVoice? mixerVoice,
    required Playback? speakerPlayback,
    required double gain,
    required bool looping,
  }) : _mixerVoice = mixerVoice,
       _speakerPlayback = speakerPlayback,
       _gain = gain,
       _looping = looping,
       _inactive = false {
    Future.wait<void>(<Future<void>>[
      if (mixerVoice case final mixer?) mixer.onComplete,
      if (speakerPlayback case final speaker?) speaker.onComplete,
    ]).then<void>(
      (_) => _settle(),
      onError: (Object error, StackTrace stack) => _settle(error, stack),
    );
  }

  SoundboardVoice._inactive(this._board, this.clip)
    : _mixerVoice = null,
      _speakerPlayback = null,
      _gain = 0,
      _looping = false,
      _inactive = true;

  final Soundboard _board;
  final Clip clip;
  final MixerVoice? _mixerVoice;
  final Playback? _speakerPlayback;
  final bool _inactive;
  double _gain;
  bool _looping;
  bool _stopped = false;
  bool _disposed = false;
  final Completer<void> _completion = Completer<void>();

  double get gain => _gain;
  bool get looping => _looping;
  bool get isPlaying =>
      !_inactive &&
      !_stopped &&
      !_disposed &&
      ((_mixerVoice?.isPlaying ?? false) ||
          (_speakerPlayback?.isPlaying ?? false));

  Duration get position =>
      _speakerPlayback?.position ?? _mixerVoice?.position ?? Duration.zero;
  Duration get duration => clip.duration;

  /// Completes once every selected route reaches the end naturally, or when
  /// the voice is disposed. A stopped voice does not complete.
  Future<void> get onComplete =>
      _inactive ? Future<void>.value() : _completion.future;

  Future<void> setGain(double gain) async {
    if (!gain.isFinite || gain < 0) {
      throw ArgumentError.value(gain, 'gain', 'must be finite and >= 0');
    }
    _gain = gain;
    _mixerVoice?.gain = gain;
    await _applySpeakerVolume();
  }

  Future<void> setLooping(bool looping) async {
    _looping = looping;
    _mixerVoice?.looping = looping;
    await _speakerPlayback?.setLooping(looping);
  }

  Future<void> pause() async {
    _mixerVoice?.pause();
    await _speakerPlayback?.pause();
  }

  Future<void> resume() async {
    _mixerVoice?.resume();
    await _speakerPlayback?.resume();
  }

  Future<void> seek(Duration position) async {
    _mixerVoice?.seek(position);
    await _speakerPlayback?.seek(position);
  }

  Future<void> stop() async {
    if (_stopped || _disposed) return;
    _stopped = true;
    _mixerVoice?.stop();
    try {
      // Stopping is final, so release the speaker's native voice as well.
      await _speakerPlayback?.dispose();
    } finally {
      _board._voices.remove(this);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _mixerVoice?.dispose();
    try {
      await _speakerPlayback?.dispose();
    } finally {
      _board._voices.remove(this);
    }
  }

  void _settle([Object? error, StackTrace? stack]) {
    if (_completion.isCompleted || (_stopped && !_disposed)) return;
    if (error == null) {
      _completion.complete();
    } else {
      _completion.completeError(error, stack);
    }
    // Playback handles hold a native voice until disposed; release it now
    // instead of whenever (if ever) the app disposes this voice.
    unawaited(_speakerPlayback?.dispose());
  }

  Future<void> _applySpeakerVolume() async {
    await _speakerPlayback?.setVolume(_gain * _board._masterVolume);
  }
}

/// The physical microphone with live gain and the board's clip bus mixed in.
class _BoardMicBackend extends CaptureBackend {
  _BoardMicBackend(this._board, this._inner, this._sessionManagement);

  final Soundboard _board;
  final CaptureBackend _inner;
  final AudioSessionManagement _sessionManagement;

  @override
  String get name => 'soundboard(${_inner.name})';
  @override
  int get priority => _inner.priority;
  @override
  bool get isAvailable => _inner.isAvailable;
  @override
  Future<void> initialize() => _inner.initialize();
  @override
  Future<bool> hasPermission() => _inner.hasPermission();
  @override
  Future<bool> requestPermission() => _inner.requestPermission();
  @override
  Future<List<CaptureDevice>> devices() => _inner.devices();

  @override
  Future<Recording> startRecording({
    CaptureFormat format = const CaptureFormat(),
    String? deviceId,
    bool retainPcm = true,
  }) async {
    final board = _board.format;
    final Recording inner;
    if (_sessionManagement == AudioSessionManagement.application) {
      final source = _inner;
      if (source is! AudioSessionCaptureBackend) {
        throw UnsupportedError(
          'Physical microphone backend does not support application-managed audio sessions',
        );
      }
      inner = await (source as AudioSessionCaptureBackend)
          .startRecordingWithAudioSession(
            audioSessionManagement: _sessionManagement,
            format: board,
            deviceId: deviceId,
            retainPcm: retainPcm,
          );
    } else {
      inner = await _inner.startRecording(
        format: board,
        deviceId: deviceId,
        retainPcm: retainPcm,
      );
    }
    // The mix sums raw bytes, so a mic that fell back to another rate or
    // layout (the web always captures mono at the AudioContext rate) would be
    // mixed against the clip bus at the wrong speed and mislabelled.
    if (inner.format != board) {
      await inner.dispose();
      throw CaptureException(
        'the microphone delivers ${inner.format}, but the soundboard mixes '
        '$board; construct the Soundboard with the microphone\'s format',
      );
    }
    return _BoardMicRecording(_board, inner);
  }

  @override
  Future<void> dispose() => _inner.dispose();
}

/// A microphone recording with the clip bus summed into every chunk.
///
/// Each captured chunk pulls exactly its own length from the clip bus, so the
/// clips run on the microphone's clock and the two cannot drift apart.
class _BoardMicRecording implements Recording {
  _BoardMicRecording(this._board, this._inner)
    : _bytesPerFrame = _board.format.bytesPerFrame {
    _frames = StreamController<Uint8List>.broadcast(
      sync: true,
      onListen: () => _subscription ??= _inner.frames.listen(
        _onChunk,
        onError: _frames.addError,
        onDone: () {
          // A microphone that ends on its own must not keep the bus frozen.
          _tap.stop();
          _frames.close();
        },
      ),
    );
    _tap.start();
  }

  final Soundboard _board;
  final Recording _inner;
  final int _bytesPerFrame;
  late final StreamController<Uint8List> _frames;
  late final _ClipTap _tap = _ClipTap(_board);
  StreamSubscription<Uint8List>? _subscription;
  Uint8List _carry = Uint8List(0);

  @override
  RecordingState get state => _inner.state;
  @override
  bool get isRecording => _inner.isRecording;
  @override
  CaptureFormat get format => _inner.format;
  @override
  Stream<Uint8List> get frames => _frames.stream;
  @override
  Uint8List get pcm => _inner.pcm;
  @override
  Duration get duration => _inner.duration;

  // While paused the microphone delivers nothing to clock the bus by, so
  // hand it back to the mixer's timer; the clips keep real time meanwhile.
  @override
  Future<void> pause() async {
    _tap.stop();
    await _inner.pause();
  }

  @override
  Future<void> resume() async {
    await _inner.resume();
    _tap.start();
  }

  @override
  Future<Uint8List> stop() async {
    try {
      return await _inner.stop();
    } finally {
      _tap.stop();
    }
  }

  @override
  Future<String> stopToFile(String path) async {
    try {
      return await _inner.stopToFile(path);
    } finally {
      _tap.stop();
    }
  }

  @override
  Future<void> dispose() async {
    _tap.stop();
    await _subscription?.cancel();
    _subscription = null;
    await _inner.dispose();
    if (!_frames.isClosed) await _frames.close();
  }

  void _onChunk(Uint8List chunk) {
    // Only whole frames line clip samples up with the right channels.
    var bytes = chunk;
    if (_carry.isNotEmpty) {
      bytes = Uint8List(_carry.length + chunk.length)
        ..setAll(0, _carry)
        ..setAll(_carry.length, chunk);
    }
    final whole = bytes.length - bytes.length % _bytesPerFrame;
    _carry = Uint8List.fromList(Uint8List.sublistView(bytes, whole));
    if (whole == 0) return;

    final clip = ByteData.sublistView(_tap.take(whole ~/ _bytesPerFrame));
    final mic = ByteData.sublistView(bytes, 0, whole);
    final out = Uint8List(whole);
    final view = ByteData.sublistView(out);
    final gain = _board.micVolume;
    for (var i = 0; i < whole; i += 2) {
      final sum =
          mic.getInt16(i, Endian.little) * gain +
          clip.getInt16(i, Endian.little);
      view.setInt16(i, sum.clamp(-32768.0, 32767.0).round(), Endian.little);
    }
    _frames.add(out);
  }
}

/// One microphone recording's view of the board's clip bus.
///
/// The first recording takes the mixer's clock and pulls exactly the frames
/// each microphone chunk needs. A recording that finds the clock taken (two
/// recordings at once) listens to the bus instead and buffers what the
/// clocking recording pulls.
class _ClipTap {
  _ClipTap(this._board);

  final Soundboard _board;
  MixerClock? _clock;
  StreamSubscription<Uint8List>? _subscription;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  void start() {
    if (_clock != null || _subscription != null || _board._disposed) return;
    _clock = _board._mixer.attachClock();
    if (_clock == null) {
      _subscription = _board.mixedFrames.listen(_buffer.add);
    }
  }

  /// The next [frames] of the clip bus, silence where it has none.
  Uint8List take(int frames) {
    final clock = _clock;
    if (clock != null) return clock.pull(frames);
    final wanted = frames * _board.format.bytesPerFrame;
    final out = Uint8List(wanted);
    if (_buffer.isEmpty) return out;
    final all = _buffer.takeBytes();
    // Never let a follower fall more than a second behind the clocking mic.
    final keep = _board.format.bytesPerSecond;
    final start = all.length > keep + wanted ? all.length - keep - wanted : 0;
    final end = start + wanted < all.length ? start + wanted : all.length;
    out.setRange(0, end - start, all, start);
    if (end < all.length) _buffer.add(Uint8List.sublistView(all, end));
    return out;
  }

  void stop() {
    _clock?.detach();
    _clock = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _buffer.clear();
  }
}
