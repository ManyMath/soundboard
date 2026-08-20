import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart' show CaptureFormat;

/// A platform virtual microphone fed with interleaved S16LE PCM.
///
/// Concrete adapters may create a virtual device directly (PipeWire) or feed
/// an installed loopback driver (BlackHole and VB-CABLE).
abstract interface class VirtualMicrophone {
  /// The input-device name other applications select.
  String get deviceName;

  /// Format accepted by [feed].
  CaptureFormat get format;

  /// Feeds the device until [pcm] closes or [dispose] is called. Call once.
  Future<void> feed(Stream<Uint8List> pcm);

  /// Stops feeding and releases platform resources.
  Future<void> dispose();
}
