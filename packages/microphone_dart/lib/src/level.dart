import 'dart:math' as math;
import 'dart:typed_data';

import 'capture_format.dart';
import 'recording.dart';

/// A loudness reading of a chunk of captured audio.
///
/// Both [rms] and [peak] are linear amplitudes in `0..1` (full scale). Use
/// [rmsDbfs] / [peakDbfs] for a decibel scale (`0` dBFS is full scale, quieter
/// is negative).
class AudioLevel {
  const AudioLevel({required this.rms, required this.peak});

  /// A reading of pure silence.
  static const AudioLevel silent = AudioLevel(rms: 0, peak: 0);

  /// Root-mean-square amplitude, `0..1`. Tracks perceived loudness.
  final double rms;

  /// Highest absolute sample amplitude, `0..1`. Catches transients/clipping.
  final double peak;

  /// [rms] on a dBFS scale (`0` at full scale, `-inf` at silence).
  double get rmsDbfs => _dbfs(rms);

  /// [peak] on a dBFS scale (`0` at full scale, `-inf` at silence).
  double get peakDbfs => _dbfs(peak);

  static double _dbfs(double amplitude) => amplitude <= 0
      ? double.negativeInfinity
      : 20 * (math.log(amplitude) / math.ln10);

  /// Computes the level of one chunk of interleaved S16LE PCM.
  ///
  /// All channels are considered together. Returns [silent] for an empty chunk.
  factory AudioLevel.fromPcm(Uint8List pcm, CaptureFormat format) {
    assert(
      format.sampleFormat == SampleFormat.int16,
      'only int16 PCM is supported',
    );
    final samples = Int16List.sublistView(
      pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.length),
    );
    if (samples.isEmpty) return silent;
    var sumSquares = 0.0;
    var peak = 0.0;
    for (final s in samples) {
      final n = s / 32768.0;
      sumSquares += n * n;
      final a = n.abs();
      if (a > peak) peak = a;
    }
    final rms = math.sqrt(sumSquares / samples.length);
    return AudioLevel(rms: rms.clamp(0, 1), peak: peak.clamp(0, 1));
  }

  @override
  String toString() =>
      'AudioLevel(rms: ${rms.toStringAsFixed(3)}, peak: ${peak.toStringAsFixed(3)})';
}

/// Level-metering conveniences over a [Recording].
extension RecordingLevels on Recording {
  /// A stream of [AudioLevel] readings derived from [frames].
  ///
  /// Emits one reading per captured chunk -- the cadence follows the backend's
  /// frame delivery (roughly every 50 ms for the native backends). For a fixed
  /// cadence, sample this with your own timer. Closes when [frames] closes.
  Stream<AudioLevel> levels() =>
      frames.map((chunk) => AudioLevel.fromPcm(chunk, format));
}
