import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  group('Android permission', () {
    const channel = MethodChannel('microphone_flutter/permission');
    final calls = <String>[];
    var granted = false;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // Stands in for MicrophoneFlutterPlugin.kt: the dialog grants access.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return switch (call.method) {
              'hasPermission' => granted,
              'requestPermission' => granted = true,
              _ => throw MissingPluginException(),
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
      Microphone.permissionDelegate = null;
      calls.clear();
      granted = false;
    });

    test('ensureInitialized installs a channel-backed delegate', () async {
      Microphone.registerBackend(SilentBackend(), makeActive: true);
      await MicrophoneFlutter.ensureInitialized();
      final permissions = Microphone.permissionDelegate!;

      expect(await permissions.hasPermission(), isFalse);
      expect(await permissions.requestPermission(), isTrue);
      expect(await permissions.hasPermission(), isTrue);
      expect(calls, ['hasPermission', 'requestPermission', 'hasPermission']);
    });

    test('Microphone permission calls reach the channel via ffi', () async {
      // What the plugin registrant does at startup; no ensureInitialized.
      MicrophoneFlutter.registerWith();
      // The FFI backend only loads the native library to capture, so it can
      // be pinned here without one.
      Microphone.useBackend('ffi');

      expect(await Microphone.hasPermission(), isFalse);
      expect(await Microphone.requestPermission(), isTrue);
      expect(calls, ['hasPermission', 'requestPermission']);
    });

    test('keeps a delegate the app installed', () async {
      final own = _GrantedPermissions();
      Microphone.permissionDelegate = own;
      Microphone.registerBackend(SilentBackend(), makeActive: true);
      await MicrophoneFlutter.ensureInitialized();
      expect(Microphone.permissionDelegate, same(own));
    });

    test('is not installed on other platforms', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      Microphone.registerBackend(SilentBackend(), makeActive: true);
      MicrophoneFlutter.registerWith();
      await MicrophoneFlutter.ensureInitialized();
      expect(Microphone.permissionDelegate, isNull);
    });
  });
}

class _GrantedPermissions implements MicrophonePermissionDelegate {
  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> requestPermission() async => true;
}
