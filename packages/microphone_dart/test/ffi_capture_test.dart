@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart';
import 'package:microphone_dart/src/backends/native/native_backend_ffi.dart';
import 'package:test/test.dart';

void main() {
  // The whole group needs the native library and a microphone, neither of which
  // CI has; it self-skips when the library cannot be loaded. On a dev host the
  // first run may prompt for microphone permission.
  final available = NativeLibrary.open() != null;

  group(
    'FFI capture (end-to-end)',
    () {
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
        // Some audio was actually captured.
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

      test('dispose is idempotent and stop-after-dispose is safe', () async {
        Microphone.registerBackend(FfiBackend(), makeActive: true);
        final recording = await Microphone.record();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await recording.dispose();
        await recording.dispose(); // no throw
        final wav = await recording.stop(); // no throw
        expect(_ascii(wav, 0, 4), 'RIFF');
      });
    },
    skip: available ? false : 'microphone library not built',
  );
}

String _ascii(Uint8List bytes, int start, int end) =>
    String.fromCharCodes(bytes.sublist(start, end));
