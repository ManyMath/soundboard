/// The sample encoding captured frames use.
///
/// Only signed 16-bit little-endian PCM is captured today; the enum leaves room
/// for float or 24-bit later without churning the API.
enum SampleFormat {
  /// Signed 16-bit little-endian PCM. Two bytes per sample.
  int16,
}

/// Bytes per sample for a [SampleFormat].
extension SampleFormatSize on SampleFormat {
  int get bytesPerSample => switch (this) {
    SampleFormat.int16 => 2,
  };
}

/// Describes the audio a recording should capture.
///
/// ## Resample policy
///
/// The requested [sampleRate] and [channels] are a request, not a guarantee.
/// Backends honor them where the platform can (macOS/iOS AudioQueue and the web
/// resample to the requested rate internally; on macOS this is verified for
/// 8/16/44.1/48 kHz, mono and stereo). A backend that cannot reconfigure the
/// device falls back to the device's native format. Either way the [Recording]
/// reports the format actually in effect via [Recording.format] -- always read
/// it rather than assuming the request was met. Captured audio is always
/// [SampleFormat.int16].
class CaptureFormat {
  const CaptureFormat({
    this.sampleRate = 44100,
    this.channels = 1,
    this.sampleFormat = SampleFormat.int16,
  }) : assert(sampleRate > 0, 'sampleRate must be positive'),
       assert(channels > 0, 'channels must be positive');

  /// Frames per second (e.g. 44100, 48000).
  final int sampleRate;

  /// Channel count (1 mono, 2 stereo).
  final int channels;

  /// Per-sample encoding.
  final SampleFormat sampleFormat;

  /// Bytes per frame: [channels] samples, each [SampleFormat.bytesPerSample].
  int get bytesPerFrame => channels * sampleFormat.bytesPerSample;

  /// Bytes per second of audio in this format.
  int get bytesPerSecond => sampleRate * bytesPerFrame;

  CaptureFormat copyWith({
    int? sampleRate,
    int? channels,
    SampleFormat? sampleFormat,
  }) => CaptureFormat(
    sampleRate: sampleRate ?? this.sampleRate,
    channels: channels ?? this.channels,
    sampleFormat: sampleFormat ?? this.sampleFormat,
  );

  @override
  bool operator ==(Object other) =>
      other is CaptureFormat &&
      other.sampleRate == sampleRate &&
      other.channels == channels &&
      other.sampleFormat == sampleFormat;

  @override
  int get hashCode => Object.hash(sampleRate, channels, sampleFormat);

  @override
  String toString() =>
      'CaptureFormat($sampleRate Hz, $channels ch, ${sampleFormat.name})';
}
