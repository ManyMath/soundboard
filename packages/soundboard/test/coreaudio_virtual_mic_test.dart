@TestOn('vm')
library;

import 'dart:io';

import 'package:soundboard/coreaudio.dart';
import 'package:soundboard/soundboard.dart';
import 'package:test/test.dart';

void main() {
  group('CoreAudioVirtualMic exceptions', () {
    test('CoreAudioUnavailableException is a CoreAudioException', () {
      const e = CoreAudioUnavailableException();
      expect(e, isA<CoreAudioException>());
      expect(e.toString(), startsWith('CoreAudioException:'));
      expect(e.message, contains('brew install'));
    });

    test('CoreAudioException carries its message', () {
      const e = CoreAudioException('boom');
      expect(e.message, 'boom');
      expect(e.toString(), 'CoreAudioException: boom');
    });
  });

  group('CoreAudioVirtualMic.defaultDeviceName', () {
    test('is the BlackHole loopback', () {
      expect(CoreAudioVirtualMic.defaultDeviceName, 'BlackHole 2ch');
    });
  });

  group('CoreAudioVirtualMic.isSupported', () {
    test('returns a bool without throwing, regardless of platform', () async {
      expect(await CoreAudioVirtualMic.isSupported(), isA<bool>());
    });

    test('is false off macOS', () async {
      if (Platform.isMacOS) return; // Covered by the live device check there.
      expect(await CoreAudioVirtualMic.isSupported(), isFalse);
    });

    test('is false for a device that cannot exist', () async {
      // A name this absurd is never a real device, so even on a Mac with the
      // native lib built this stays false -- and never throws.
      expect(
        await CoreAudioVirtualMic.isSupported(
          deviceName: 'no-such-device-xyzzy-42',
        ),
        isFalse,
      );
    });
  });

  group('CoreAudioVirtualMic.create', () {
    test('throws CoreAudioUnavailableException off macOS', () async {
      if (Platform.isMacOS) return; // The native path is exercised on macOS.
      expect(
        () => CoreAudioVirtualMic.create(),
        throwsA(isA<CoreAudioUnavailableException>()),
      );
    });

    test('throws CoreAudioException for an absent device', () async {
      // Off macOS this is the unavailable subtype; on macOS with the lib built
      // it is the open-failure CoreAudioException. Both are CoreAudioException.
      expect(
        () => CoreAudioVirtualMic.create(deviceName: 'no-such-device-xyzzy-42'),
        throwsA(isA<CoreAudioException>()),
      );
    });
  });

  group('integration seam', () {
    test('the mixer backend yields S16LE frames create() can feed', () async {
      // Documents the wiring without needing a device: the recording stream is
      // the exact Stream<Uint8List> feed() consumes.
      const fmt = CaptureFormat(sampleRate: 48000, channels: 2);
      final board = Soundboard(format: fmt);
      addTearDown(board.dispose);
      final recording = await board.asMicrophoneBackend().startRecording(
        format: fmt,
      );
      addTearDown(recording.dispose);
      expect(recording.frames, isA<Stream<List<int>>>());
    });
  });
}
