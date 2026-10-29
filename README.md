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

The device-independent mixer is its own repository,
`ssh://git@ssh.manymath.com:2222/sneurlax/mixer.git`. That makes resampling, channel adaptation, gain, looping, seeking, and
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
`mixer_dart`. The clip bus sums voices in floating point and clamps once at its
S16LE output; the microphone mix then adds that bus to the physical microphone
and clamps the sum again.

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

Private Gitea CI verifies the pinned integration.

## Workspace

The workspace contains Soundboard, its Flutter wrapper and its example app.
Sound, microphone and mixer are separate canonical repositories. The root
manifest pins their private Gitea revisions, recorded in `tool/integration.json`;
no sibling checkout or vendored source is required.

```sh
flutter pub get --enforce-lockfile
dart run tool/check_integration.dart
dart test packages/soundboard
flutter test packages/soundboard_flutter/test
flutter test apps/soundboard_example/test
```

The integration gate verifies actual resolved commits and original package
version constraints, so overrides cannot silently mask a version mismatch.
These private application pins are not a public package dependency contract.
The owner must mirror the exact source revisions and publish sound_dart and
microphone_dart before their Flutter wrappers in the later public phase.
`soundboard` and `soundboard_flutter` are publishable once `sound_*` and `microphone_*` 0.0.2 are on pub.dev and the private overrides above are removed. The example app stays `publish_to: none`.

## Shared iOS session

An app coordinating playback and capture owns the iOS audio session. Configure
and activate a record-capable session before starting either audio operation,
then select `AudioSessionManagement.application` when creating the board's
physical-microphone backend:

```dart
final capture = board.asMicrophoneBackend(
  audioSessionManagement: AudioSessionManagement.application,
);
final recording = await capture.startRecording(retainPcm: false);
```

The app handles interruptions, routes and recovery, and deactivates only after
all playback and capture have stopped. Microphone never deactivates on an
individual recording's stop. Unsupported physical backends fail explicitly.
Automatic session behavior remains the default for existing callers. Select
ownership on `asMicrophoneBackend`; the returned mixing backend uses that
configuration when registered through `Microphone` as well.

Combined tests verify independent playback/capture lifetimes using synthetic
input and a silent speaker. They do not prove iOS hardware behavior. Device
acceptance still includes simultaneous playback/capture, interruption recovery,
route changes, and the optional desktop virtual-microphone drivers.

## License

MIT. See [LICENSE](LICENSE).
