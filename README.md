# soundboard

Soundboard functionality in Dart and Flutter using Rust, aspiring to add no
additional dependencies.

`soundboard` routes and mixes played audio into a microphone capture stream. It
combines clips played from disk or memory with the physical microphone into a
single capture stream that any consumer of `microphone_dart` can read -- a
soundboard for calls, streams, and recordings.

## What it does (Phase 1: in-process mixer)

```
[clips from disk/memory] --(sound_dart decode + PCM tap)--+
                                                          +--> Dart PCM mixer --> microphone CaptureBackend --> app
[physical microphone] -----(microphone_dart capture)------+
```

The mixer is pure Dart: it sums the clip bus and the microphone bus, applies
per-bus gain, and clamps to the 16-bit sample range. The result is presented as
a `microphone_dart` `CaptureBackend`, so a consuming app selects soundboard's
backend instead of the default hardware backend and receives microphone plus
clips, mixed.

This works on every platform the upstream packages already support, with no OS
driver. The longer-term goal -- an OS-level virtual microphone device selectable
by other apps (Zoom, Discord, browsers) -- has a working **Linux/PipeWire**
prototype (`package:soundboard/pipewire.dart`, `PipeWireVirtualMic`).

## Layout

This is a melos monorepo that vendors two upstream ManyMath packages and adds
one new package on top:

- `sound/` -- vendored `ManyMath/sound` (Rust decode + playback, `sound_dart`,
  `sound_flutter`).
- `microphone/` -- vendored `ManyMath/microphone` (Rust capture,
  `microphone_dart`, `microphone_flutter`).
- `packages/soundboard/` -- the new pure-Dart package that wires the two
  together.

`soundboard` depends on `sound_dart` and `microphone_dart` via path
dependencies. Flutter apps additionally depend on `sound_flutter` and
`microphone_flutter`, which build the native Rust libraries via cargokit.

## Usage

```dart
import 'package:soundboard/soundboard.dart';

final board = Soundboard();
final clip = await board.loadFile('applause.wav');

// Hand the combined backend to any microphone_dart consumer.
final backend = board.asMicrophoneBackend();

board.play(clip);            // mix the clip into the capture stream
board.masterVolume = 0.8;    // clip bus gain
board.micVolume = 1.0;       // physical mic bus gain
```

See `packages/soundboard/example/` for a complete example.

## License

MIT. See [LICENSE](LICENSE).
