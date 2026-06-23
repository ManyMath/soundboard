import 'package:flutter_test/flutter_test.dart';
import 'package:microphone_flutter/microphone_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => Microphone.reset());
  tearDown(() => Microphone.reset());

  test('re-exports the microphone_dart API', () {
    // The Microphone entry point and core types come through the re-export.
    Microphone.registerBackend(SilentBackend(), makeActive: true);
    expect(Microphone.backend.name, 'silent');
  });

  test('ensureInitialized returns the active backend name', () async {
    Microphone.registerBackend(SilentBackend(), makeActive: true);
    expect(await MicrophoneFlutter.ensureInitialized(), 'silent');
  });
}
