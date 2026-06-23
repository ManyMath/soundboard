import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart';
import 'package:test/test.dart';

/// Builds an interleaved S16LE chunk from sample values.
Uint8List pcm(List<int> samples) {
  final out = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return out;
}

void main() {
  const format = CaptureFormat();

  group('AudioLevel.fromPcm', () {
    test('silence reads zero', () {
      final level = AudioLevel.fromPcm(pcm([0, 0, 0, 0]), format);
      expect(level.rms, 0);
      expect(level.peak, 0);
      expect(level.rmsDbfs, double.negativeInfinity);
    });

    test('empty chunk is silent', () {
      expect(AudioLevel.fromPcm(Uint8List(0), format), AudioLevel.silent);
    });

    test('full-scale samples read ~1.0', () {
      final level = AudioLevel.fromPcm(pcm([32767, -32768, 32767]), format);
      expect(level.peak, closeTo(1.0, 0.001));
      expect(level.rms, closeTo(1.0, 0.001));
      expect(level.peakDbfs, closeTo(0, 0.01));
    });

    test('peak tracks the loudest sample, rms the average energy', () {
      // One loud transient among quiet samples: peak high, rms lower.
      final level = AudioLevel.fromPcm(pcm([32767, 0, 0, 0]), format);
      expect(level.peak, closeTo(1.0, 0.001));
      expect(level.rms, closeTo(0.5, 0.01)); // sqrt(1/4)
      expect(level.rms, lessThan(level.peak));
    });

    test('half-scale is about -6 dBFS', () {
      final level = AudioLevel.fromPcm(pcm([16384, -16384]), format);
      expect(level.peakDbfs, closeTo(-6.02, 0.1));
    });
  });

  group('RecordingLevels.levels', () {
    test('maps each frame chunk to a level reading', () async {
      Microphone.registerBackend(SilentBackend(), makeActive: true);
      final recording = await Microphone.record();
      final readings = <AudioLevel>[];
      final sub = recording.levels().listen(readings.add);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await recording.stop();
      await sub.cancel();
      expect(readings, isNotEmpty);
      // The silent backend captures zeros, so every reading is silent.
      expect(readings.every((l) => l.rms == 0 && l.peak == 0), isTrue);
      await Microphone.reset();
    });
  });
}
