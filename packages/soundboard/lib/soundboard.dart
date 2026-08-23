/// Route and mix played sound into a microphone capture stream.
///
/// `soundboard` combines clips played from disk or memory with the physical
/// microphone into a single capture stream that any `microphone_dart` consumer
/// can read. It is pure Dart, built on top of `sound_dart` (decoding and the
/// PCM tap) and `microphone_dart` (capture and the stream/mixing backends).
///
/// The entry point is [Soundboard]; see its [Soundboard.asMicrophoneBackend].
library;

// Re-export the capture-side pieces a soundboard consumer needs. (The silent
// and no-backend symbols are intentionally omitted: both upstream packages
// define their own, so exporting them here would clash.)
export 'package:microphone_dart/microphone_dart.dart'
    show
        AudioLevel,
        CaptureBackend,
        CaptureDevice,
        CaptureException,
        CaptureFormat,
        Microphone,
        MicrophoneException,
        MixingCaptureBackend,
        Recording,
        RecordingLevels,
        RecordingState,
        SampleFormat,
        StreamCaptureBackend;
export 'package:sound_dart/sound_dart.dart'
    show SoundException, SoundSource, UnsupportedSourceException;

export 'src/clip.dart';
export 'src/soundboard.dart';
export 'src/virtual_microphone.dart';
