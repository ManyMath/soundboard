/// Linux-only: expose a soundboard as a PipeWire virtual microphone device
/// that other applications can select as their input.
///
/// This entry point is separate from `package:soundboard/soundboard.dart` so the
/// cross-platform library stays free of `dart:io` (and therefore web-safe).
/// Import it only on Linux:
///
/// ```dart
/// import 'package:soundboard/soundboard.dart';
/// import 'package:soundboard/pipewire.dart';
/// ```
///
/// See [PipeWireVirtualMic].
library;

export 'src/linux/pipewire_virtual_mic.dart';
