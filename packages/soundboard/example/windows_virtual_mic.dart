// Windows example: feed the soundboard into a VB-CABLE virtual cable so other
// apps (Discord, a game, Voice Recorder) can select it as their microphone.
//
// Prerequisites on Windows:
//   1. Install the VB-CABLE driver from VB-Audio (restart if prompted).
//   2. Build the native sink library:
//        cargo build --manifest-path sound/native/sound_cli/Cargo.toml
//
// Then run:
//
//   dart run example/windows_virtual_mic.dart
//
// Pick "CABLE Output" as the microphone in any app and press Enter here to
// hear a beep mixed into that app's mic input. If the cable cannot be opened,
// the error lists the playback devices WinMM enumerated.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:soundboard/soundboard.dart';
import 'package:soundboard/windows.dart';

Future<void> main() async {
  const fmt = CaptureFormat(sampleRate: 48000, channels: 2);
  final WindowsVirtualMic vmic;
  try {
    // create() rather than isSupported(): its error says what went wrong.
    vmic = await WindowsVirtualMic.create(format: fmt);
  } on WindowsVirtualMicException catch (e) {
    stderr.writeln('$e');
    exitCode = 1;
    return;
  }

  final board = Soundboard(format: fmt);
  final beep = board.loadBytes(
    _sine(660, const Duration(milliseconds: 350), fmt),
    format: fmt,
  );

  // mic + clips -> a recording whose frames we stream into the cable.
  // retainPcm: false -- the session is open-ended, so do not accumulate it.
  final recording = await board.asMicrophoneBackend().startRecording(
    format: fmt,
    retainPcm: false,
  );
  // feed() completes when the stream closes or dispose() is called; a failure
  // while live (cable removed) surfaces here.
  unawaited(
    vmic.feed(recording.frames).catchError((Object e) {
      stderr.writeln('feeding stopped: $e');
    }),
  );

  late final StreamSubscription<ProcessSignal> sigint;
  Future<void> shutdown() async {
    await sigint.cancel();
    await recording.dispose();
    await vmic.dispose();
    await board.dispose();
  }

  sigint = ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nStopping...');
    await shutdown();
    exit(0);
  });

  stdout.writeln('Feeding "${vmic.sinkDeviceName}".');
  stdout.writeln('Select "${vmic.deviceName}" as your input in any app.');
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
