/// Cross-platform microphone capture for Dart and Flutter.
///
/// `microphone_dart` is pure Dart and has no Flutter dependency, so it works
/// in CLI tools as well as Flutter apps. Native capture is reached over FFI;
/// see [CaptureBackend] for the pluggable backend contract and [Microphone] for
/// the entry point.
library;

export 'src/backends/silent_backend.dart';
export 'src/capture_backend.dart';
export 'src/capture_device.dart';
export 'src/capture_format.dart';
export 'src/exceptions.dart';
export 'src/level.dart';
export 'src/microphone.dart';
export 'src/recording.dart';
export 'src/wav.dart';
