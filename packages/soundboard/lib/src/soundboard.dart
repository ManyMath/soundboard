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
  Stream<Uint8List> get mixedFrames => _mixer.frames;

  /// Loads and decodes any `sound_dart` [SoundSource].
  Future<Clip> load(SoundSource source) async {
    final stream = await Sound.openPcmStream(source);
    try {
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

    final voice = SoundboardVoice._(
      this,
      clip,
      mixerVoice: mixerVoice,
      speakerPlayback: speakerPlayback,
      gain: gain,
      looping: looping,
    );
    _voices.add(voice);
    unawaited(voice.onComplete.then((_) => _voices.remove(voice)));
    return voice;
  }

  /// Stops every active voice. The physical microphone is unaffected.
  Future<void> stopAll() async {
    final voices = List<SoundboardVoice>.of(_voices);
    _mixer.stopAll();
    await Future.wait(voices.map((voice) => voice.stop()));
    _voices.clear();
  }

  /// A capture backend yielding the physical microphone plus [mixedFrames].
  ///
  /// Resolve [physicalMic] before registering the result as the active global
  /// backend, or the soundboard would feed itself. For an open-ended session,
  /// use `retainPcm: false` when starting the returned backend.
  CaptureBackend asMicrophoneBackend({CaptureBackend? physicalMic}) {
    final mic = _GainCaptureBackend(
      physicalMic ?? Microphone.backend,
      () => micVolume,
      format,
    );
    final clips = StreamCaptureBackend(source: mixedFrames, format: format);
    return MixingCaptureBackend(
      <CaptureBackend>[mic, clips],
      format: format,
      primary: 0,
      ownsSources: false,
    );
  }

  /// Stops all voices and releases the mixer.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final voices = List<SoundboardVoice>.of(_voices);
    await Future.wait(voices.map((voice) => voice.dispose()));
    _voices.clear();
    await _mixer.dispose();
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
       _inactive = false;

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

  /// Completes once every selected route reaches the end naturally.
  Future<void> get onComplete {
    if (_inactive) return Future<void>.value();
    return Future.wait<void>(<Future<void>>[
      if (_mixerVoice case final mixer?) mixer.onComplete,
      if (_speakerPlayback case final speaker?) speaker.onComplete,
    ]);
  }

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
    await _speakerPlayback?.stop();
    _board._voices.remove(this);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _mixerVoice?.dispose();
    await _speakerPlayback?.dispose();
    _board._voices.remove(this);
  }

  Future<void> _applySpeakerVolume() async {
    await _speakerPlayback?.setVolume(_gain * _board._masterVolume);
  }
}

/// Applies a live gain to a capture backend's streamed frames.
class _GainCaptureBackend extends CaptureBackend {
  _GainCaptureBackend(this._inner, this._gain, this._format);

  final CaptureBackend _inner;
  final double Function() _gain;
  final CaptureFormat _format;

  @override
  String get name => 'gain(${_inner.name})';
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
    final inner = await _inner.startRecording(
      format: _format,
      deviceId: deviceId,
      retainPcm: retainPcm,
    );
    return _GainRecording(inner, _gain);
  }

  @override
  Future<void> dispose() => _inner.dispose();
}

class _GainRecording implements Recording {
  _GainRecording(this._inner, this._gain);

  final Recording _inner;
  final double Function() _gain;

  @override
  RecordingState get state => _inner.state;
  @override
  bool get isRecording => _inner.isRecording;
  @override
  CaptureFormat get format => _inner.format;
  @override
  Stream<Uint8List> get frames => _inner.frames.map(_scale);
  @override
  Uint8List get pcm => _inner.pcm;
  @override
  Duration get duration => _inner.duration;
  @override
  Future<void> pause() => _inner.pause();
  @override
  Future<void> resume() => _inner.resume();
  @override
  Future<Uint8List> stop() => _inner.stop();
  @override
  Future<String> stopToFile(String path) => _inner.stopToFile(path);
  @override
  Future<void> dispose() => _inner.dispose();

  Uint8List _scale(Uint8List chunk) {
    final gain = _gain();
    if (gain == 1) return chunk;
    final out = Uint8List(chunk.length);
    final input = ByteData.sublistView(chunk);
    final output = ByteData.sublistView(out);
    for (var i = 0; i < chunk.length ~/ 2; i++) {
      final sample = (input.getInt16(i * 2, Endian.little) * gain)
          .round()
          .clamp(-32768, 32767);
      output.setInt16(i * 2, sample, Endian.little);
    }
    return out;
  }
}
