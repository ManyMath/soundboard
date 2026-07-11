// Linux example: expose the soundboard as a PipeWire virtual microphone that
// other apps (Zoom, Discord, a browser) can select as their input.
//
// Run on a Linux desktop with PipeWire:
//
//   dart run example/linux_virtual_mic.dart
//
// Then pick "Soundboard" as the microphone in any app and press Enter here to
// hear a beep mixed into that app's mic input. On a machine where the
// microphone native library is built, your live voice is mixed in too;
// otherwise the microphone bus is silent and you hear only the clips.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:soundboard/pipewire.dart';
import 'package:soundboard/soundboard.dart';

Future<void> main() async {
  if (!await PipeWireVirtualMic.isSupported()) {
    stderr.writeln(
      'PipeWire virtual microphone is not available here. It needs Linux with '
      'a running PipeWire session and the pw-loopback and pw-cat tools '
      '(install the "pipewire" package).',
    );
    exitCode = 1;
    return;
  }

  const fmt = CaptureFormat(sampleRate: 48000, channels: 1);
  final board = Soundboard(format: fmt);
  final beep = board.loadBytes(
    _sine(660, const Duration(milliseconds: 350), fmt),
    format: fmt,
  );

  // mic + clips -> a recording whose frames we stream into the virtual device.
  // retainPcm: false -- the session is open-ended, so do not accumulate it.
  final recording = await board.asMicrophoneBackend().startRecording(
    format: fmt,
    retainPcm: false,
  );
  final vmic = await PipeWireVirtualMic.create(name: 'Soundboard', format: fmt);
  // feed() completes when the stream closes or dispose() is called; a failure
  // while live (pw-cat died) surfaces here.
  unawaited(
    vmic.feed(recording.frames).catchError((Object e) {
      stderr.writeln('feeding stopped: $e');
    }),
  );

  // Clean up the device if the user hits Ctrl-C.
  late final StreamSubscription<ProcessSignal> sigint;
  Future<void> shutdown() async {
    await sigint.cancel();
    await vmic.dispose();
    await board.dispose();
  }

  sigint = ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nStopping...');
    await shutdown();
    exit(0);
  });

  stdout.writeln('Virtual microphone "${vmic.name}" is live.');
  stdout.writeln('Select it as your input in any app.');
  stdout.writeln(
    'Press Enter to play a beep into it; type q then Enter to quit.',
  );

  await for (final line
      in stdin
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())) {
    if (line.trim().toLowerCase() == 'q') break;
    board.play(beep);
    stdout.writeln('beep');
  }

  await shutdown();
}

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
