// macOS example: expose the soundboard as a CoreAudio virtual microphone that
// other apps (Zoom, Discord, a browser) can select as their input.
//
// Prerequisites on macOS:
//   1. Install a loopback device once:  brew install blackhole-2ch
//   2. Build the native sink library:
//        cargo build --manifest-path sound/native/sound_cli/Cargo.toml
//
// Then run:
//
//   dart run example/macos_virtual_mic.dart
//
// Pick "BlackHole 2ch" as the microphone in any app and press Enter here to
// hear a beep mixed into that app's mic input. On a machine where the
// microphone native library is built, your live voice is mixed in too;
// otherwise the microphone bus is silent and you hear only the clips.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:soundboard/coreaudio.dart';
import 'package:soundboard/soundboard.dart';

Future<void> main() async {
  if (!await CoreAudioVirtualMic.isSupported()) {
    stderr.writeln(
      'CoreAudio virtual microphone is not available here. It needs macOS with '
      'a loopback device (install one with "brew install blackhole-2ch") and '
      'the built sound_cli native library (cargo build --manifest-path '
      'sound/native/sound_cli/Cargo.toml).',
    );
    exitCode = 1;
    return;
  }

  // BlackHole 2ch is stereo; match it so the mix needs no up-mixing here (the
  // native sink would up-mix mono anyway).
  const fmt = CaptureFormat(sampleRate: 48000, channels: 2);
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
  final vmic = await CoreAudioVirtualMic.create(format: fmt);
  // feed() completes when the stream closes or dispose() is called; a failure
  // while live (device removed) surfaces here.
  unawaited(
    vmic.feed(recording.frames).catchError((Object e) {
      stderr.writeln('feeding stopped: $e');
    }),
  );

  // Clean up the device if the user hits Ctrl-C.
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

  stdout.writeln('Virtual microphone "${vmic.deviceName}" is live.');
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
