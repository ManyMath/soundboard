# soundboard

Cross-platform soundboard playback and virtual-microphone routing for Dart and
Flutter.

The project is split at the framework boundary:

- `soundboard` is pure Dart. It decodes clips through `sound_dart`, plays them
  through speakers, and routes independently controlled voices into a reusable
  `mixer_dart` PCM graph.
- `soundboard_flutter` re-exports that API, brings in the `sound_flutter` and
  `microphone_flutter` native build plugins, initializes both backends, and
  loads Flutter assets. Its separate `desktop.dart` entry point exports the
  platform virtual-microphone adapters.
- `apps/soundboard_example` demonstrates physical-microphone selection, clips,
  gains, and a system-visible virtual microphone.

The device-independent mixer is its own sibling project at `~/src/hardware/mixer`.
That makes resampling, channel adaptation, gain, looping, seeking, and
pause/resume reusable by projects other than Soundboard.

## Audio routes

```
decoded clip ----+----> sound_dart speaker playback
                 |
                 +----> mixer_dart clip bus ---+
physical mic ----------------------------------+--> mixed capture --> virtual mic
```

`Soundboard.play` defaults to both speakers and the microphone bus. Pass an
explicit `outputs` set for speaker-only or microphone-only playback. Each call
returns a `SoundboardVoice` with gain, loop, pause/resume, seek, stop, position,
duration, and completion controls.

```dart
final board = Soundboard();
final applause = await board.loadFile('applause.wav');
final voice = await board.play(applause, gain: 0.8);

await voice.pause();
await voice.seek(const Duration(milliseconds: 200));
await voice.resume();

final backend = board.asMicrophoneBackend();
final recording = await backend.startRecording(retainPcm: false);
```

Clips are converted to the board's sample rate and channel layout by
`mixer_dart`. Mixing uses a floating-point accumulator and clamps once at the
S16LE output boundary.

## Flutter

Flutter applications depend on `soundboard_flutter` rather than assembling the
three lower-level packages themselves:

```dart
import 'package:soundboard_flutter/soundboard_flutter.dart';

await SoundboardFlutter.ensureInitialized();
final board = Soundboard();
final clip = await SoundboardFlutter.loadAsset(board, 'assets/chime.wav');
await board.play(clip);
```

## System virtual microphones

- Linux: `PipeWireVirtualMic` creates a process-scoped PipeWire source and
  feeder using `pw-loopback`, `pw-cat`, and `pw-cli`.
- macOS: `CoreAudioVirtualMic` feeds an installed BlackHole loopback device via
  the native named CoreAudio sink.
- Windows: `WindowsVirtualMic` feeds an installed VB-CABLE playback endpoint;
  applications select its paired `CABLE Output` recording endpoint.

All implement the common pure-Dart `VirtualMicrophone` contract. macOS and
Windows need a loopback driver installed once; a future branded driver can
replace either without changing Soundboard's feeding model. Mobile and web can
use the in-app mix but cannot publish a system-wide microphone through public
platform APIs.

CI is intentionally deferred.

## Workspace

The Soundboard workspace includes `sound_dart`, `sound_flutter`,
`microphone_dart`, `microphone_flutter`, `soundboard`, `soundboard_flutter`, and
their examples. During sibling development, the root workspace overrides the
`mixer_dart` Git dependency to `~/src/hardware/mixer/packages/mixer_dart`.

## License

MIT. See [LICENSE](LICENSE).
