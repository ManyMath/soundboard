import 'dart:async';
import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart';
import 'package:test/test.dart';

/// Builds interleaved S16LE bytes from signed sample values.
Uint8List pcm16(List<int> samples) {
  final out = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return out;
}

/// Reads interleaved S16LE bytes back into signed sample values.
List<int> samples16(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  return [
    for (var i = 0; i < bytes.length ~/ 2; i++)
      view.getInt16(i * 2, Endian.little),
  ];
}

/// Lets queued stream events drain between steps.
Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 15));

const _fmt = CaptureFormat(sampleRate: 8000, channels: 1);

void main() {
  group('StreamCaptureBackend', () {
    test('republishes injected frames and accumulates them', () async {
      final ctrl = StreamController<Uint8List>();
      final backend = StreamCaptureBackend(source: ctrl.stream, format: _fmt);
      final rec = await backend.startRecording();
      final received = <int>[];
      final sub = rec.frames.listen((c) => received.addAll(samples16(c)));

      ctrl.add(pcm16([1, 2, 3]));
      ctrl.add(pcm16([4, 5]));
      await pump();

      expect(samples16(rec.pcm), [1, 2, 3, 4, 5]);
      expect(received, [1, 2, 3, 4, 5]);
      await sub.cancel();
      await ctrl.close();
    });

    test('reports the injected format, not the requested one', () async {
      final ctrl = StreamController<Uint8List>();
      final backend = StreamCaptureBackend(source: ctrl.stream, format: _fmt);
      final rec = await backend.startRecording(
        format: const CaptureFormat(sampleRate: 48000, channels: 2),
      );
      expect(rec.format, _fmt);
      await rec.stop();
      await ctrl.close();
    });

    test('drops audio while paused, continues on resume', () async {
      final ctrl = StreamController<Uint8List>();
      final backend = StreamCaptureBackend(source: ctrl.stream, format: _fmt);
      final rec = await backend.startRecording();

      ctrl.add(pcm16([1, 2]));
      await pump();
      await rec.pause();
      ctrl.add(pcm16([9, 9])); // arrives while paused -> dropped
      await pump();
      expect(samples16(rec.pcm), [1, 2]);

      await rec.resume();
      ctrl.add(pcm16([3, 4]));
      await pump();
      expect(samples16(rec.pcm), [1, 2, 3, 4]);
      await rec.stop();
      await ctrl.close();
    });

    test('stop returns well-formed WAV bytes', () async {
      final ctrl = StreamController<Uint8List>();
      final backend = StreamCaptureBackend(source: ctrl.stream, format: _fmt);
      final rec = await backend.startRecording();
      ctrl.add(pcm16([1, 2, 3, 4]));
      await pump();
      final wav = await rec.stop();
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      final view = ByteData.sublistView(wav);
      expect(view.getUint32(24, Endian.little), 8000); // sample rate
      expect(view.getUint32(40, Endian.little), wav.length - 44); // data size
      await ctrl.close();
    });

    test('a closed source closes frames and stops the recording', () async {
      final ctrl = StreamController<Uint8List>();
      final backend = StreamCaptureBackend(source: ctrl.stream, format: _fmt);
      final rec = await backend.startRecording();
      var closed = false;
      rec.frames.listen((_) {}, onDone: () => closed = true);
      ctrl.add(pcm16([1, 2]));
      await ctrl.close();
      await pump();
      expect(closed, isTrue);
      expect(rec.state, RecordingState.stopped);
    });
  });

  group('MixingCaptureBackend', () {
    /// Wraps a controller's stream as a capture source in [_fmt].
    StreamCaptureBackend source(StreamController<Uint8List> ctrl) =>
        StreamCaptureBackend(source: ctrl.stream, format: _fmt);

    test('sums the primary with buffered secondary samples', () async {
      final primary = StreamController<Uint8List>();
      final other = StreamController<Uint8List>();
      final mixing = MixingCaptureBackend([
        source(primary),
        source(other),
      ], format: _fmt);
      final rec = await mixing.startRecording();

      // Buffer the secondary, then clock a primary chunk that consumes it.
      other.add(pcm16([100, 200, 300]));
      await pump();
      primary.add(pcm16([10, 20, 30]));
      await pump();

      expect(samples16(rec.pcm), [110, 220, 330]);
      await rec.stop();
      await primary.close();
      await other.close();
    });

    test('clamps the summed result to the 16-bit range', () async {
      final primary = StreamController<Uint8List>();
      final other = StreamController<Uint8List>();
      final mixing = MixingCaptureBackend([
        source(primary),
        source(other),
      ], format: _fmt);
      final rec = await mixing.startRecording();

      other.add(pcm16([20000, -20000]));
      await pump();
      primary.add(pcm16([20000, -20000]));
      await pump();

      expect(samples16(rec.pcm), [32767, -32768]);
      await rec.stop();
      await primary.close();
      await other.close();
    });

    test(
      'an idle secondary contributes silence (primary passes through)',
      () async {
        final primary = StreamController<Uint8List>();
        final other = StreamController<Uint8List>();
        final mixing = MixingCaptureBackend([
          source(primary),
          source(other),
        ], format: _fmt);
        final rec = await mixing.startRecording();

        primary.add(pcm16([7, 8, 9])); // nothing buffered from `other`
        await pump();

        expect(samples16(rec.pcm), [7, 8, 9]);
        await rec.stop();
        await primary.close();
        await other.close();
      },
    );

    test('a shorter secondary mixes only where it has samples', () async {
      final primary = StreamController<Uint8List>();
      final other = StreamController<Uint8List>();
      final mixing = MixingCaptureBackend([
        source(primary),
        source(other),
      ], format: _fmt);
      final rec = await mixing.startRecording();

      other.add(pcm16([1000])); // only one sample
      await pump();
      primary.add(pcm16([1, 2, 3]));
      await pump();

      expect(samples16(rec.pcm), [1001, 2, 3]);
      await rec.stop();
      await primary.close();
      await other.close();
    });

    test('output ends when the primary source ends', () async {
      final primary = StreamController<Uint8List>();
      final other = StreamController<Uint8List>();
      final mixing = MixingCaptureBackend([
        source(primary),
        source(other),
      ], format: _fmt);
      final rec = await mixing.startRecording();
      var closed = false;
      rec.frames.listen((_) {}, onDone: () => closed = true);

      primary.add(pcm16([1, 2]));
      await pump();
      await primary.close(); // primary ends
      await pump();

      expect(closed, isTrue);
      expect(rec.state, RecordingState.stopped);
      await other.close();
    });

    test('mixed frames feed level metering', () async {
      final primary = StreamController<Uint8List>();
      final other = StreamController<Uint8List>();
      final mixing = MixingCaptureBackend([
        source(primary),
        source(other),
      ], format: _fmt);
      final rec = await mixing.startRecording();
      final levels = <AudioLevel>[];
      final sub = rec.levels().listen(levels.add);

      other.add(pcm16([16384, 16384]));
      await pump();
      primary.add(pcm16([16384, 16384])); // sum 32768 -> clamps to 32767
      await pump();

      expect(levels, isNotEmpty);
      expect(levels.last.peak, closeTo(1.0, 0.001));
      await sub.cancel();
      await rec.stop();
      await primary.close();
      await other.close();
    });

    test('mixes through the Microphone registry like any backend', () async {
      final primary = StreamController<Uint8List>();
      final other = StreamController<Uint8List>();
      final mixing = MixingCaptureBackend([
        source(primary),
        source(other),
      ], format: _fmt);
      Microphone.registerBackend(mixing, makeActive: true);
      addTearDown(Microphone.reset);

      final rec = await Microphone.record();
      other.add(pcm16([5, 5]));
      await pump();
      primary.add(pcm16([5, 5]));
      await pump();
      expect(samples16(rec.pcm), [10, 10]);
      await rec.stop();
      await primary.close();
      await other.close();
    });
  });
}
