@TestOn('vm')
library;

import 'package:microphone_dart/microphone_dart.dart';
import 'package:microphone_dart/src/backends/native/native_backend_ffi.dart';
import 'package:test/test.dart';

/// Stands in for a platform permission API: denied until requested.
class _FakePermissions implements MicrophonePermissionDelegate {
  bool granted = false;
  int checks = 0;
  int requests = 0;

  @override
  Future<bool> hasPermission() async {
    checks++;
    return granted;
  }

  @override
  Future<bool> requestPermission() async {
    requests++;
    return granted = true;
  }
}

void main() {
  // None of this touches the native library; FfiBackend only loads it for
  // capture and device enumeration.
  tearDown(() async {
    Microphone.permissionDelegate = null;
    await Microphone.reset();
  });

  test('the FFI backend reports granted with no delegate', () async {
    final backend = FfiBackend();
    expect(await backend.hasPermission(), isTrue);
    expect(await backend.requestPermission(), isTrue);
  });

  test('the FFI backend defers to the installed delegate', () async {
    final permissions = _FakePermissions();
    Microphone.permissionDelegate = permissions;
    final backend = FfiBackend();

    expect(await backend.hasPermission(), isFalse);
    expect(await backend.requestPermission(), isTrue);
    expect(await backend.hasPermission(), isTrue);
    expect(permissions.checks, 2);
    expect(permissions.requests, 1);
  });

  test('Microphone permission calls reach the delegate', () async {
    final permissions = _FakePermissions();
    Microphone.permissionDelegate = permissions;
    Microphone.registerBackend(FfiBackend(), makeActive: true);

    expect(await Microphone.hasPermission(), isFalse);
    expect(await Microphone.requestPermission(), isTrue);
    expect(permissions.requests, 1);
  });

  test('reset keeps the delegate', () async {
    final permissions = _FakePermissions();
    Microphone.permissionDelegate = permissions;
    await Microphone.reset();
    expect(Microphone.permissionDelegate, same(permissions));
  });
}
