import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart';
import 'package:sound_dart/sound_dart.dart';

import 'clip.dart';

/// Routes and mixes played sound into a microphone capture stream.
///
/// Load clips with [loadFile] or [loadBytes], then mix them into a capture
/// stream that any `microphone_dart` consumer can read. The combined stream
/// (physical microphone plus active clips) is obtained from
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
  Soundboard({this.format = const CaptureFormat()});

  /// The format of the mixed capture stream. Clips and the microphone are mixed
  /// into this format.
  final CaptureFormat format;

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
}
