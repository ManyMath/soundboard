@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart';
import 'package:microphone_dart/platform_hooks.dart';
import 'package:microphone_dart/src/backends/native/native_backend_ffi.dart';
import 'package:test/test.dart';

void main() {
  // The whole group needs the native library and a microphone, neither of which
  // CI has; it self-skips when the library cannot be loaded. On a dev host the
  // first run may prompt for microphone permission.
  final available = NativeLibrary.open() != null;

  group('FFI capture (end-to-end)', () {
    setUp(() => Microphone.reset());
    tearDown(() => Microphone.reset());

    test('records a short clip and returns a well-formed WAV', () async {
      final backend = FfiBackend();
      expect(backend.isAvailable, isTrue);
      Microphone.registerBackend(backend, makeActive: true);

      final recording = await Microphone.record(
        format: const CaptureFormat(sampleRate: 44100, channels: 1),
      );
      expect(recording.isRecording, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      final wav = await recording.stop();

      // Header well-formed.
      expect(_ascii(wav, 0, 4), 'RIFF');
      expect(_ascii(wav, 8, 12), 'WAVE');
      expect(_ascii(wav, 36, 40), 'data');
      final view = ByteData.sublistView(wav);
      expect(view.getUint32(40, Endian.little), wav.length - 44);
      // Some audio was captured.
      expect(wav.length, greaterThan(44));
      expect(recording.duration, greaterThan(Duration.zero));
      await recording.dispose();
    });

    test('frames stream delivers PCM and closes on stop', () async {
      Microphone.registerBackend(FfiBackend(), makeActive: true);
      final recording = await Microphone.record();
      final chunks = <int>[];
      final sub = recording.frames.listen((c) => chunks.add(c.length));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await recording.stop();
      await sub.cancel();
      expect(chunks, isNotEmpty);
      await recording.dispose();
    });

    test('reports the format actually in effect', () async {
      Microphone.registerBackend(FfiBackend(), makeActive: true);
      final recording = await Microphone.record(
        format: const CaptureFormat(sampleRate: 44100, channels: 1),
      );
      expect(recording.format.sampleRate, greaterThan(0));
      expect(recording.format.channels, greaterThan(0));
      await recording.stop();
      await recording.dispose();
    });

    test('pause drops audio, resume continues', () async {
      Microphone.registerBackend(FfiBackend(), makeActive: true);
      final recording = await Microphone.record();
      // Capture a bit, then pause.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await recording.pause();
      expect(recording.state, RecordingState.paused);
      // Let time pass while paused; the native side discards input, so the
      // accumulated PCM must not grow (allow one in-flight poll's slack).
      final atPause = recording.pcm.length;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(recording.pcm.length - atPause, lessThan(8192));
      // Resume and confirm capture grows again.
      await recording.resume();
      expect(recording.isRecording, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(recording.pcm.length, greaterThan(atPause));
      await recording.stop();
      await recording.dispose();
    });

    test('honors a non-default sample rate and stereo', () async {
      Microphone.registerBackend(FfiBackend(), makeActive: true);
      // 16 kHz mono.
      final mono = await Microphone.record(
        format: const CaptureFormat(sampleRate: 16000, channels: 1),
      );
      expect(mono.format.sampleRate, 16000);
      expect(mono.format.channels, 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await mono.stop();
      await mono.dispose();
      // 44.1 kHz stereo.
      final stereo = await Microphone.record(
        format: const CaptureFormat(sampleRate: 44100, channels: 2),
      );
      expect(stereo.format.channels, 2);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await stereo.stop();
      await stereo.dispose();
    });

    test('enumerates input devices with a default', () async {
      Microphone.registerBackend(FfiBackend(), makeActive: true);
      final devices = await Microphone.devices();
      // A dev Mac has at least the built-in mic.
      expect(devices, isNotEmpty);
      expect(devices.where((d) => d.isDefault), isNotEmpty);
      expect(devices.every((d) => d.id.isNotEmpty), isTrue);
      expect(devices.every((d) => d.label.isNotEmpty), isTrue);
    });

    test('records from a selected device by id', () async {
      Microphone.registerBackend(FfiBackend(), makeActive: true);
      final devices = await Microphone.devices();
      final device = devices.firstWhere((d) => d.isDefault);
      final recording = await Microphone.record(deviceId: device.id);
      expect(recording.isRecording, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final wav = await recording.stop();
      expect(wav.length, greaterThan(44));
      await recording.dispose();
    });

    test('stop drains audio queued while the isolate was busy', () async {
      Microphone.registerBackend(FfiBackend(), makeActive: true);
      final recording = await Microphone.record(
        format: const CaptureFormat(sampleRate: 48000, channels: 2),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // Block the event loop so no poll runs: well over one read buffer's
      // worth of audio piles up natively and must all come out on stop.
      final busy = Stopwatch()..start();
      while (busy.elapsedMilliseconds < 1000) {}
      await recording.stop();
      expect(
        recording.duration,
        greaterThan(const Duration(milliseconds: 1000)),
      );
      await recording.dispose();
    });

    test('a mix keeps the microphone audio drained on stop', () async {
      const format = CaptureFormat(sampleRate: 48000, channels: 1);
      final mixing = MixingCaptureBackend([
        FfiBackend(),
        SilentBackend(),
      ], format: format);
      Microphone.registerBackend(mixing, makeActive: true);
      final recording = await Microphone.record();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // Leave the capture to the final drain in stop().
      final busy = Stopwatch()..start();
      while (busy.elapsedMilliseconds < 600) {}
      await recording.stop();
      expect(
        recording.duration,
        greaterThan(const Duration(milliseconds: 600)),
      );
      await recording.dispose();
    });

    test('frames events hold whole frames', () async {
      Microphone.registerBackend(FfiBackend(), makeActive: true);
      // Three channels do not divide the read buffer evenly; block the event
      // loop so the backlog spans several full reads.
      final recording = await Microphone.record(
        format: const CaptureFormat(sampleRate: 48000, channels: 3),
      );
      final sizes = <int>[];
      recording.frames.listen((c) => sizes.add(c.length));
      final busy = Stopwatch()..start();
      while (busy.elapsedMilliseconds < 500) {}
      await recording.stop();
      expect(sizes, isNotEmpty);
      final bytesPerFrame = recording.format.bytesPerFrame;
      expect(sizes.where((n) => n % bytesPerFrame != 0), isEmpty);
      await recording.dispose();
    });

    test('disposing the backend stops its live recordings', () async {
      final backend = FfiBackend();
      Microphone.registerBackend(backend, makeActive: true);
      final recording = await Microphone.record();
      var closed = false;
      recording.frames.listen(null, onDone: () => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await backend.dispose();
      expect(recording.state, RecordingState.stopped);
      expect(closed, isTrue);
      final captured = recording.pcm.length;
      expect(captured, greaterThan(0));

      // Reusing the backend starts a fresh recorder whose recording ids
      // restart; the old handle must not pick up the new capture.
      await backend.initialize();
      final next = await backend.startRecording();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(recording.pcm.length, captured);
      expect(next.pcm, isNotEmpty);
      await next.dispose();
      await recording.dispose();
      await backend.dispose();
    });

    test('permission is not gated on this host', () async {
      final backend = FfiBackend();
      expect(await backend.hasPermission(), isTrue);
      expect(await backend.requestPermission(), isTrue);
    });

    group('with NativePlatform permission hooks', () {
      tearDown(() {
        NativePlatform.checkPermission = null;
        NativePlatform.requestPermission = null;
      });

      test('record asks first and fails when refused', () async {
        var asked = 0;
        NativePlatform.checkPermission = () async => false;
        NativePlatform.requestPermission = () async {
          asked++;
          return false;
        };
        Microphone.registerBackend(FfiBackend(), makeActive: true);
        expect(await Microphone.hasPermission(), isFalse);
        await expectLater(
          Microphone.record(),
          throwsA(isA<PermissionDeniedException>()),
        );
        expect(asked, 1);
      });

      test('record proceeds once the request is granted', () async {
        var granted = false;
        NativePlatform.checkPermission = () async => granted;
        NativePlatform.requestPermission = () async => granted = true;
        Microphone.registerBackend(FfiBackend(), makeActive: true);
        final recording = await Microphone.record();
        expect(granted, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect((await recording.stop()).length, greaterThan(44));
        await recording.dispose();
      });
    });

    test('dispose is idempotent and stop-after-dispose is safe', () async {
      Microphone.registerBackend(FfiBackend(), makeActive: true);
      final recording = await Microphone.record();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await recording.dispose();
      await recording.dispose(); // no throw
      final wav = await recording.stop(); // no throw
      expect(_ascii(wav, 0, 4), 'RIFF');
    });
  }, skip: available ? false : 'microphone library not built');
}

String _ascii(Uint8List bytes, int start, int end) =>
    String.fromCharCodes(bytes.sublist(start, end));
