// Records from the microphone using `microphone_dart` (pure Dart, no
// Flutter) and writes a WAV file.
//
// Build the native library first:
//   cargo build --manifest-path native/microphone/Cargo.toml
// then, from the repo root:
//   dart run packages/microphone_dart/example/microphone_example.dart
//   dart run packages/microphone_dart/example/microphone_example.dart out.wav 5
//
// Until the native backend lands the active backend is `silent`, which records
// silence so the plumbing is exercised end to end. If the library is elsewhere,
// point to it with MICROPHONE_LIB=/path/to/lib.

import 'dart:io';

import 'package:microphone_dart/microphone_dart.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args.first : 'recording.wav';
  final seconds = args.length > 1 ? int.tryParse(args[1]) ?? 3 : 3;

  print('Active backend: ${Microphone.backend.name}');

  if (!await Microphone.hasPermission()) {
    print('Requesting microphone permission...');
    if (!await Microphone.requestPermission()) {
      stderr.writeln('Microphone permission denied.');
      exit(1);
    }
  }

  print('Recording $seconds second(s) to $path...');
  final recording = await Microphone.record();

  // Show a running byte count off the live frame stream.
  var captured = 0;
  final sub = recording.frames.listen((chunk) {
    captured += chunk.length;
    stdout.write('\rcaptured ${captured ~/ 1024} KiB');
  });

  await Future<void>.delayed(Duration(seconds: seconds));
  await recording.stopToFile(path);
  await sub.cancel();

  print('\nDone: ${recording.duration.inMilliseconds} ms in $path.');
  await recording.dispose();
}
