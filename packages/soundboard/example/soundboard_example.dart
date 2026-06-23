// A self-contained soundboard example: mix a synthesized beep over the
// microphone and record the result to a WAV file.
//
// Run from the package directory:
//
//   dart run example/soundboard_example.dart
//
// In a headless environment the microphone backend is silent, so the output
// contains just the beep. On a machine with a real microphone, the beep is
// mixed over your live mic input -- which is what a downstream app (a call, a
// stream) would receive if it read from this soundboard backend.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:soundboard/soundboard.dart';

Future<void> main() async {
  const format = CaptureFormat(sampleRate: 44100, channels: 1);
  final board = Soundboard(format: format);

  // Synthesize a half-second 440 Hz beep as a clip, so the example needs no
  // audio file on disk. loadFile(path) would decode a real WAV/MP3/OGG/FLAC.
  final beep = board.loadBytes(
    _sine(440, const Duration(milliseconds: 500), format),
    format: format,
  );

  // Present the combined stream (physical microphone + active clips) as a
  // microphone backend, and make it the one Microphone.record() uses. The
  // physical mic defaults to the platform's current Microphone.backend.
  Microphone.registerBackend(board.asMicrophoneBackend(), makeActive: true);

  final recording = await Microphone.record(format: format);
  stdout.writeln('Recording microphone + soundboard...');

  // Trigger the beep into the mix partway through.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  board.play(beep);
  await Future<void>.delayed(const Duration(milliseconds: 1200));

  final wav = await recording.stop();
  await board.dispose();

  const path = 'soundboard_mix.wav';
  await File(path).writeAsBytes(wav);
  stdout.writeln('Wrote $path (${wav.length} bytes).');
}

/// Builds a mono/stereo S16LE sine tone of [freq] Hz lasting [dur].
Uint8List _sine(double freq, Duration dur, CaptureFormat fmt) {
  final frames = fmt.sampleRate * dur.inMilliseconds ~/ 1000;
  final out = Uint8List(frames * fmt.channels * 2);
  final view = ByteData.sublistView(out);
  var o = 0;
  for (var i = 0; i < frames; i++) {
    final v = (0.3 * sin(2 * pi * freq * i / fmt.sampleRate) * 32767).round();
    for (var c = 0; c < fmt.channels; c++) {
      view.setInt16(o, v, Endian.little);
      o += 2;
    }
  }
  return out;
}
