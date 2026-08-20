import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart' show CaptureFormat;
import 'package:mixer_dart/mixer_dart.dart' show PcmClip, PcmFormat;

/// A decoded audio clip held in memory, ready to be mixed into a soundboard.
///
/// Samples are interleaved signed 16-bit little-endian PCM -- the shape both
/// `sound_dart`'s decoder and `microphone_dart`'s capture use -- so a clip
/// mixes into a capture stream with no format conversion.
class Clip {
  Clip({
    required this.samples,
    required this.sampleRate,
    required this.channels,
  }) : assert(sampleRate > 0, 'sampleRate must be positive'),
       assert(channels > 0, 'channels must be positive'),
       assert(
         samples.length % channels == 0,
         'samples must contain complete interleaved frames',
       );

  /// Interleaved S16LE samples.
  final Int16List samples;

  /// Sample rate in Hz.
  final int sampleRate;

  /// Channel count (1 mono, 2 stereo).
  final int channels;

  /// Number of frames (one frame is one sample per channel).
  int get frameCount => samples.length ~/ channels;

  /// The clip's length in time.
  Duration get duration => Duration(
    microseconds: frameCount * Duration.microsecondsPerSecond ~/ sampleRate,
  );

  /// The clip's format expressed as a [CaptureFormat].
  CaptureFormat get format =>
      CaptureFormat(sampleRate: sampleRate, channels: channels);

  /// This clip as the device-independent type consumed by `mixer_dart`.
  PcmClip get pcmClip => PcmClip(
    samples: samples,
    format: PcmFormat(sampleRate: sampleRate, channels: channels),
  );

  /// Wraps raw interleaved S16LE [pcm] described by [format].
  ///
  /// The bytes are copied into a private buffer and read little-endian, so the
  /// result is independent of the host byte order and of later edits to [pcm].
  factory Clip.fromPcm(Uint8List pcm, CaptureFormat format) {
    final count = pcm.length ~/ 2;
    final samples = Int16List(count);
    final view = ByteData.sublistView(pcm);
    for (var i = 0; i < count; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little);
    }
    return Clip(
      samples: samples,
      sampleRate: format.sampleRate,
      channels: format.channels,
    );
  }
}
