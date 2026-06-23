/// Route and mix played sound into a microphone capture stream.
///
/// `soundboard` combines clips played from disk or memory with the physical
/// microphone into a single capture stream that any `microphone_dart` consumer
/// can read. It is pure Dart, built on top of `sound_dart` (decoding and the
/// PCM tap) and `microphone_dart` (capture and the stream/mixing backends).
///
/// The entry point is [Soundboard]; see its [Soundboard.asMicrophoneBackend].
library;

export 'package:microphone_dart/microphone_dart.dart'
    show CaptureBackend, CaptureFormat, SampleFormat;

export 'src/clip.dart';
export 'src/soundboard.dart';
