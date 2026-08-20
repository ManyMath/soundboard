/// Flutter integration for the pure-Dart `soundboard` package.
///
/// This package brings in the `sound_flutter` and `microphone_flutter` native
/// build plugins, re-exports the Soundboard API, and adds Flutter asset loading.
/// Desktop virtual-microphone adapters are exported separately by
/// `package:soundboard_flutter/desktop.dart` to keep this entry point free of
/// `dart:io` and FFI.
library;

import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:microphone_flutter/microphone_flutter.dart';
import 'package:sound_flutter/sound_flutter.dart';
import 'package:soundboard/soundboard.dart';

export 'package:soundboard/soundboard.dart';

/// Names of the native backends selected during Flutter initialization.
typedef SoundboardFlutterBackends = ({String sound, String microphone});

/// Flutter-specific initialization and asset conveniences.
abstract final class SoundboardFlutter {
  /// Eagerly initializes both native audio plugins.
  static Future<SoundboardFlutterBackends> ensureInitialized() async {
    final (sound, microphone) = await (
      SoundFlutter.ensureInitialized(),
      MicrophoneFlutter.ensureInitialized(),
    ).wait;
    return (sound: sound, microphone: microphone);
  }

  /// Decodes a bundled Flutter asset into a reusable [Clip].
  static Future<Clip> loadAsset(
    Soundboard board,
    String assetPath, {
    String? package,
    AssetBundle? bundle,
  }) async {
    final key = package == null ? assetPath : 'packages/$package/$assetPath';
    final data = await (bundle ?? rootBundle).load(key);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return board.load(
      SoundSource.bytes(bytes, format: _extensionOf(assetPath)),
    );
  }

  /// Loads and triggers a bundled Flutter asset.
  static Future<SoundboardVoice> playAsset(
    Soundboard board,
    String assetPath, {
    String? package,
    AssetBundle? bundle,
    double gain = 1,
    bool looping = false,
    Set<SoundboardOutput>? outputs,
  }) async {
    final clip = await loadAsset(
      board,
      assetPath,
      package: package,
      bundle: bundle,
    );
    return board.play(clip, gain: gain, looping: looping, outputs: outputs);
  }

  static String? _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf('/');
    if (dot < 0 || dot < slash || dot == path.length - 1) return null;
    return path.substring(dot + 1).toLowerCase();
  }
}
