import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart';
import 'package:test/test.dart';

/// A backend whose availability and priority are configurable, for exercising
/// selection logic.
class _ProbeBackend extends CaptureBackend {
  _ProbeBackend(this.name, {this.available = true, this.priority = 0});

  @override
  final String name;
  final bool available;
  @override
  final int priority;

  int initializeCalls = 0;

  @override
  bool get isAvailable => available;

  @override
  Future<void> initialize() async => initializeCalls++;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<CaptureDevice>> devices() async => const [];

  @override
  Future<Recording> startRecording({
    CaptureFormat format = const CaptureFormat(),
    String? deviceId,
  }) async => SilentRecording(format, const Duration(milliseconds: 10));

  @override
  Future<void> dispose() async {}
}

void main() {
  tearDown(() => Microphone.reset());

  group('backend selection', () {
    // Probe priorities are kept well above the real defaults (silent at -1000)
    // so these tests are deterministic regardless of host hardware.
    test('always registers the silent fallback', () {
      expect(Microphone.backends.map((b) => b.name), contains('silent'));
      expect(Microphone.backend.isAvailable, isTrue);
    });

    test('prefers the highest-priority available backend', () {
      Microphone.registerBackend(_ProbeBackend('low', priority: 5000));
      Microphone.registerBackend(_ProbeBackend('high', priority: 9000));
      expect(Microphone.backend.name, 'high');
    });

    test('skips unavailable backends', () {
      Microphone.registerBackend(
        _ProbeBackend('unavailable', priority: 9999, available: false),
      );
      Microphone.registerBackend(_ProbeBackend('usable', priority: 9000));
      expect(Microphone.backend.name, 'usable');
    });

    test('re-selects when a higher-priority backend is registered later', () {
      final first = Microphone.backend.name;
      Microphone.registerBackend(_ProbeBackend('better', priority: 9000));
      expect(Microphone.backend.name, 'better');
      expect(first, isNot('better'));
    });

    test('makeActive pins a backend regardless of priority', () {
      Microphone.registerBackend(_ProbeBackend('high', priority: 9000));
      final low = _ProbeBackend('low', priority: 1);
      Microphone.registerBackend(low, makeActive: true);
      expect(Microphone.backend.name, 'low');
    });

    test('useBackend pins by name and throws on unknown', () {
      Microphone.registerBackend(_ProbeBackend('a', priority: 1));
      Microphone.registerBackend(_ProbeBackend('b', priority: 2));
      Microphone.useBackend('a');
      expect(Microphone.backend.name, 'a');
      expect(
        () => Microphone.useBackend('nope'),
        throwsA(isA<NoBackendAvailableException>()),
      );
    });
  });

  group('recording lifecycle', () {
    test('record starts via the active backend', () async {
      final silent = SilentBackend();
      Microphone.registerBackend(silent, makeActive: true);
      final recording = await Microphone.record();
      expect(silent.started, hasLength(1));
      expect(recording.isRecording, isTrue);
      await recording.stop();
      expect(recording.state, RecordingState.stopped);
    });

    test('devices lists the active backend inputs', () async {
      Microphone.registerBackend(SilentBackend(), makeActive: true);
      final devices = await Microphone.devices();
      expect(devices, hasLength(1));
      expect(devices.single.isDefault, isTrue);
    });

    test('initialize is called once per backend', () async {
      final probe = _ProbeBackend('probe', priority: 10);
      Microphone.registerBackend(probe, makeActive: true);
      await Microphone.record();
      await Microphone.record();
      expect(probe.initializeCalls, 1);
    });

    test('stop returns well-formed WAV bytes', () async {
      Microphone.registerBackend(SilentBackend(), makeActive: true);
      final recording = await Microphone.record(
        format: const CaptureFormat(sampleRate: 8000, channels: 1),
      );
      // Let a couple of chunks accumulate.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final wav = await recording.stop();
      expect(_ascii(wav, 0, 4), 'RIFF');
      expect(_ascii(wav, 8, 12), 'WAVE');
      expect(_ascii(wav, 36, 40), 'data');
      // Header reports 8 kHz mono 16-bit.
      final view = ByteData.sublistView(wav);
      expect(view.getUint16(22, Endian.little), 1); // channels
      expect(view.getUint32(24, Endian.little), 8000); // sample rate
      expect(view.getUint16(34, Endian.little), 16); // bits per sample
      // data size matches the byte length.
      expect(view.getUint32(40, Endian.little), wav.length - 44);
    });

    test('frames stream delivers PCM and closes on stop', () async {
      Microphone.registerBackend(SilentBackend(), makeActive: true);
      final recording = await Microphone.record();
      final chunks = <int>[];
      final done = recording.frames.listen((c) => chunks.add(c.length));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await recording.stop();
      await done.cancel();
      expect(chunks, isNotEmpty);
      expect(chunks.every((n) => n > 0), isTrue);
    });

    test('pause stops accumulation; resume continues', () async {
      Microphone.registerBackend(SilentBackend(), makeActive: true);
      final recording = await Microphone.record();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await recording.pause();
      expect(recording.state, RecordingState.paused);
      final atPause = recording.pcm.length;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(recording.pcm.length, atPause); // no growth while paused
      await recording.resume();
      expect(recording.isRecording, isTrue);
      await recording.stop();
    });

    test('stop is idempotent', () async {
      Microphone.registerBackend(SilentBackend(), makeActive: true);
      final recording = await Microphone.record();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final first = await recording.stop();
      final second = await recording.stop();
      expect(second.length, first.length);
    });
  });

  group('registry robustness', () {
    test('registering the same instance twice is idempotent', () {
      final probe = _ProbeBackend('probe', priority: 9000);
      Microphone.registerBackend(probe);
      Microphone.registerBackend(probe);
      expect(Microphone.backends.where((b) => b.name == 'probe'), hasLength(1));
    });

    test('reset clears the registry and re-seeds defaults', () async {
      Microphone.registerBackend(_ProbeBackend('probe', priority: 9000));
      expect(Microphone.backend.name, 'probe');
      await Microphone.reset();
      expect(Microphone.backends.map((b) => b.name), contains('silent'));
      expect(Microphone.backends.map((b) => b.name), isNot(contains('probe')));
    });
  });

  group('CaptureFormat', () {
    test('derives frame and byte rates', () {
      const f = CaptureFormat(sampleRate: 48000, channels: 2);
      expect(f.bytesPerFrame, 4); // 2 ch * 2 bytes
      expect(f.bytesPerSecond, 48000 * 4);
    });

    test('equality and copyWith', () {
      const a = CaptureFormat(sampleRate: 44100, channels: 1);
      expect(a.copyWith(channels: 2), const CaptureFormat(channels: 2));
      expect(a, const CaptureFormat());
    });
  });

  group('wavFromPcm', () {
    test('prepends a 44-byte header sized to the PCM', () {
      final pcm = Uint8List(100);
      final wav = wavFromPcm(pcm, const CaptureFormat());
      expect(wav.length, 144);
      final view = ByteData.sublistView(wav);
      expect(view.getUint32(4, Endian.little), 36 + 100); // RIFF size
      expect(view.getUint32(40, Endian.little), 100); // data size
    });
  });
}

String _ascii(Uint8List bytes, int start, int end) =>
    String.fromCharCodes(bytes.sublist(start, end));
