/// macOS-only: expose a soundboard as a CoreAudio virtual microphone device
/// that other applications can select as their input.
///
/// This entry point is separate from `package:soundboard/soundboard.dart` so the
/// cross-platform library stays free of `dart:io`/FFI (and therefore web-safe).
/// Import it only on macOS:
///
/// ```dart
/// import 'package:soundboard/soundboard.dart';
/// import 'package:soundboard/coreaudio.dart';
/// ```
///
/// It routes the mix into a loopback device (BlackHole by default; install it
/// once with `brew install blackhole-2ch`) through the native `sound_cli`
/// CoreAudio sink. See [CoreAudioVirtualMic].
library;

export 'src/macos/coreaudio_virtual_mic.dart';
