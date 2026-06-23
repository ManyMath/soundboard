# soundboard

Route and mix played sound into a microphone capture stream. Pure Dart, built on
`sound_dart` (decoding and a PCM tap) and `microphone_dart` (capture plus the
stream and mixing backends), with the goal of no additional system dependencies.

`soundboard` combines clips played from disk or memory with the physical
microphone into a single capture stream that any `microphone_dart` consumer can
read -- a soundboard for calls, streams, and recordings.

## How it works

```
[clips from disk/memory] --(sound_dart decode + PCM tap)--+
                                                          +--> clip bus --+
                                                                          +--> MixingCaptureBackend --> app
[physical microphone] -----------------(microphone_dart capture)----------+
```

- Each loaded clip is interleaved S16LE PCM held in memory (decoded by
  `sound_dart` for files, or wrapped directly for raw PCM).
- `play` adds a clip as a voice on the clip bus; the bus sums all active voices
  (channel-adapted, master-gained), clamps to 16-bit, and emits frames.
- `asMicrophoneBackend` mixes the clip bus with the physical microphone via
  `microphone_dart`'s `MixingCaptureBackend`. The microphone is the primary
  timeline: it runs continuously and clips are mixed in as they play.

The result is a `CaptureBackend`. Hand it to any `microphone_dart` consumer, or
register it with `Microphone.registerBackend(..., makeActive: true)` so
`Microphone.record()` returns the mixed stream.

## Usage

```dart
import 'package:soundboard/soundboard.dart';

final board = Soundboard();

// Load clips from a file (decoded) or from raw PCM bytes.
final applause = await board.loadFile('applause.wav');
final beep = board.loadBytes(rawPcm, format: const CaptureFormat());

// Present microphone + clips as a capture backend.
Microphone.registerBackend(board.asMicrophoneBackend(), makeActive: true);
final recording = await Microphone.record();

board.play(applause, gain: 0.8); // mix a clip in
board.masterVolume = 0.9;        // clip bus gain
board.micVolume = 1.0;           // physical mic gain
board.stopAll();                 // stop all clips (mic continues)

final wav = await recording.stop();
```

See `example/soundboard_example.dart` for a runnable example
(`dart run example/soundboard_example.dart`).

## Flutter

The pure-Dart `soundboard` package mixes and presents the backend. To get the
native libraries that actually decode audio and capture the microphone in a
Flutter app, also depend on `sound_flutter` and `microphone_flutter` (they build
the Rust libraries via cargokit) and call their `ensureInitialized()` helpers.

## Limitations (Phase 1)

- Clips are not resampled: a clip should be at the soundboard's `format` sample
  rate (channel count is adapted automatically). Resampling is future work.
- This is an in-process mixer. Exposing the mix as an OS-level virtual
  microphone device selectable by other apps is future work.

## License

MIT.
