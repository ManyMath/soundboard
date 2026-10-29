import 'dart:typed_data';

import 'package:soundboard_flutter/soundboard_flutter.dart';

class VirtualMicSupport {
  const VirtualMicSupport({
    required this.supported,
    required this.platformLabel,
    required this.hint,
  });
  final bool supported;
  final String platformLabel;
  final String hint;
}

/// The browser cannot expose an operating-system virtual microphone.
abstract class VirtualMic {
  String get deviceName;
  CaptureFormat get format;
  Future<void> feed(Stream<Uint8List> pcm);
  Future<void> dispose();
}

abstract final class VirtualMicPlatform {
  static Future<VirtualMicSupport> support() async => const VirtualMicSupport(
    supported: false,
    platformLabel: 'browser',
    hint: 'An OS-level virtual microphone requires macOS, Windows, or Linux.',
  );

  static Future<VirtualMic> create({required CaptureFormat format}) async {
    throw UnsupportedError(
      'OS-level virtual microphones are unavailable in browsers',
    );
  }
}
