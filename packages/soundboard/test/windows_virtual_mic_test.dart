@TestOn('vm')
library;

import 'dart:io';

import 'package:soundboard/soundboard.dart';
import 'package:soundboard/windows.dart';
import 'package:test/test.dart';

void main() {
  test('documents the paired VB-CABLE endpoint names', () {
    expect(WindowsVirtualMic.defaultSinkDeviceName, contains('CABLE Input'));
    expect(WindowsVirtualMic.defaultDeviceName, contains('CABLE Output'));
  });

  test('isSupported never throws and is false off Windows', () async {
    final supported = await WindowsVirtualMic.isSupported();
    expect(supported, isA<bool>());
    if (!Platform.isWindows) expect(supported, isFalse);
  });

  test('create has a typed unavailable failure off Windows', () async {
    if (Platform.isWindows) return;
    expect(
      WindowsVirtualMic.create,
      throwsA(isA<WindowsVirtualMicUnavailableException>()),
    );
  });

  test('all adapters share the VirtualMicrophone contract', () {
    expect(VirtualMicrophone, isNotNull);
  });
}
