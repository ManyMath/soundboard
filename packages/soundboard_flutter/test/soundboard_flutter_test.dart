import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sound_flutter/sound_flutter.dart' as sound;
import 'package:soundboard_flutter/soundboard_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loadAsset decodes through the pure-Dart Soundboard API', () async {
    sound.Sound.registerBackend(
      sound.SilentBackend(
        simulatedDuration: const Duration(milliseconds: 10),
        pcmSampleRate: 8000,
        pcmChannels: 1,
      ),
      makeActive: true,
    );
    addTearDown(sound.Sound.reset);
    final board = Soundboard(
      format: const CaptureFormat(sampleRate: 8000, channels: 1),
    );
    addTearDown(board.dispose);
    final bundle = _MemoryBundle();

    final clip = await SoundboardFlutter.loadAsset(
      board,
      'assets/chime.wav',
      bundle: bundle,
    );

    expect(bundle.lastKey, 'assets/chime.wav');
    expect(clip.sampleRate, 8000);
    expect(clip.channels, 1);
    expect(clip.frameCount, 80);
  });
}

final class _MemoryBundle extends CachingAssetBundle {
  String? lastKey;

  @override
  Future<ByteData> load(String key) async {
    lastKey = key;
    return ByteData.sublistView(Uint8List.fromList(<int>[1, 2, 3]));
  }
}
