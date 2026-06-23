import 'dart:async';
import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart';
import 'package:sound_dart/sound_dart.dart';

import 'clip.dart';

/// Routes and mixes played sound into a microphone capture stream.
///
/// Load clips with [loadFile] or [loadBytes], trigger them with [play], and mix
/// them into a capture stream that any `microphone_dart` consumer can read. The
/// combined stream (physical microphone plus active clips) is obtained from
/// [asMicrophoneBackend].
///
/// ```dart
/// final board = Soundboard();
/// final clip = await board.loadFile('applause.wav');
/// final backend = board.asMicrophoneBackend();
/// board.play(clip);
/// ```
///
/// All audio is interleaved S16LE at the soundboard's [format]. Clips are
/// channel-adapted to [format] when mixed; clips at a different sample rate are
/// not resampled in this phase (see the README), so prefer clips that match
/// [format].
class Soundboard {
  Soundboard({
    this.format = const CaptureFormat(),
    Duration chunk = const Duration(milliseconds: 50),
  }) {
    _clipBus = _ClipBus(format, () => masterVolume, chunk: chunk);
  }

  /// The format of the mixed capture stream. Clips and the microphone are mixed
  /// into this format.
  final CaptureFormat format;

  /// Linear gain applied to the clip bus (all clips together). `1.0` is unity.
  double masterVolume = 1.0;

  /// Linear gain applied to the physical microphone bus. `1.0` is unity.
  double micVolume = 1.0;

  late final _ClipBus _clipBus;

  /// Loads a clip from a file on disk, decoding it via `sound_dart`.
  ///
  /// Supports every container `sound_dart` decodes (WAV/MP3/OGG/FLAC). The clip
  /// keeps the file's own sample rate and channel count.
  Future<Clip> loadFile(String path) async {
    final stream = await Sound.openPcmStream(SoundSource.file(path));
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

  /// Loads a clip from raw interleaved S16LE [bytes] described by [format].
  ///
  /// Use this for already-decoded PCM (or a synthesized tone); no decoding is
  /// performed.
  Clip loadBytes(Uint8List bytes, {required CaptureFormat format}) =>
      Clip.fromPcm(bytes, format);

  /// Triggers [clip] into the mix, optionally at a per-trigger [gain].
  ///
  /// Multiple clips can play at once; they are summed on the clip bus. The same
  /// clip can be triggered repeatedly, each trigger an independent voice.
  void play(Clip clip, {double gain = 1.0}) => _clipBus.play(clip, gain);

  /// Stops every active clip immediately. The microphone is unaffected.
  void stopAll() => _clipBus.stopAll();

  /// Releases the soundboard's mixing resources.
  Future<void> dispose() => _clipBus.dispose();
}

/// Mixes the currently playing clips into a single bus stream.
///
/// On each tick it sums every active voice (each channel-adapted to the mix
/// format) into one chunk, applies the master gain, clamps to the 16-bit range,
/// and emits it. The timer only runs while clips are playing, so an idle bus
/// produces nothing -- which the mixer treats as silence.
class _ClipBus {
  _ClipBus(this._format, this._masterGain, {required Duration chunk})
    : _chunk = chunk,
      _chunkFrames =
          (_format.sampleRate * chunk.inMicroseconds) ~/
          Duration.microsecondsPerSecond;

  final CaptureFormat _format;
  final double Function() _masterGain;
  final Duration _chunk;
  final int _chunkFrames;

  final List<_ClipVoice> _voices = [];
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();
  Timer? _timer;

  /// The mixed clip-bus frames, interleaved S16LE at the mix format.
  Stream<Uint8List> get frames => _controller.stream;

  void play(Clip clip, double gain) {
    _voices.add(_ClipVoice(clip, gain));
    _timer ??= Timer.periodic(_chunk, (_) => _tick());
  }

  void stopAll() => _voices.clear();

  void _tick() {
    if (_controller.isClosed || _voices.isEmpty) {
      _stop();
      return;
    }
    final channels = _format.channels;
    final acc = Float64List(_chunkFrames * channels);
    for (final v in _voices) {
      v.mixInto(acc, _chunkFrames, channels);
    }
    _voices.removeWhere((v) => v.finished);

    final master = _masterGain();
    final out = Uint8List(acc.length * 2);
    final view = ByteData.sublistView(out);
    for (var i = 0; i < acc.length; i++) {
      var s = (acc[i] * master).round();
      if (s > 32767) {
        s = 32767;
      } else if (s < -32768) {
        s = -32768;
      }
      view.setInt16(i * 2, s, Endian.little);
    }
    if (!_controller.isClosed) _controller.add(out);
    if (_voices.isEmpty) _stop();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    _stop();
    _voices.clear();
    if (!_controller.isClosed) await _controller.close();
  }
}

/// One playing clip: a read position into the clip's samples plus its gain.
class _ClipVoice {
  _ClipVoice(this.clip, this.gain);

  final Clip clip;
  final double gain;
  int _pos = 0; // interleaved sample index

  bool get finished => _pos >= clip.samples.length;

  /// Adds up to [frames] frames of this voice, channel-adapted to
  /// [mixChannels], into [acc] (a per-sample accumulator).
  void mixInto(Float64List acc, int frames, int mixChannels) {
    final s = clip.samples;
    final cc = clip.channels;
    var p = _pos;
    for (var f = 0; f < frames && p < s.length; f++) {
      final base = f * mixChannels;
      if (cc == mixChannels) {
        for (var c = 0; c < mixChannels; c++) {
          final src = p + c;
          if (src < s.length) acc[base + c] += gain * s[src];
        }
      } else if (cc == 1) {
        final v = gain * s[p];
        for (var c = 0; c < mixChannels; c++) {
          acc[base + c] += v;
        }
      } else if (mixChannels == 1) {
        var sum = 0.0;
        for (var c = 0; c < cc && p + c < s.length; c++) {
          sum += s[p + c];
        }
        acc[base] += gain * sum / cc;
      } else {
        for (var c = 0; c < mixChannels; c++) {
          final src = p + (c % cc);
          if (src < s.length) acc[base + c] += gain * s[src];
        }
      }
      p += cc;
    }
    _pos = p;
  }
}
