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

## Linux: a real virtual microphone device

On Linux with PipeWire (the default on modern Ubuntu), the soundboard can be
published as a virtual microphone **device** that other apps -- Zoom, Discord, a
browser -- select from their own input menus, with no integration on their part.

```dart
import 'package:soundboard/soundboard.dart';
import 'package:soundboard/pipewire.dart';

const fmt = CaptureFormat(sampleRate: 48000, channels: 1);
final board = Soundboard(format: fmt);

final recording = await board.asMicrophoneBackend().startRecording(format: fmt);
final vmic = await PipeWireVirtualMic.create(name: 'Soundboard', format: fmt);
await vmic.feed(recording.frames); // stream mic + clips into the device

// ... board.play(clip) ... the app hears it on the "Soundboard" mic ...

await vmic.dispose(); // removes the device
```

It uses the `pw-loopback` and `pw-cat` tools that ship with PipeWire (no
PulseAudio CLI, no kernel driver, no pub dependency), and the device exists only
while your process runs. `PipeWireVirtualMic.isSupported()` checks the
environment first. See `example/linux_virtual_mic.dart`
(`dart run example/linux_virtual_mic.dart`).

## macOS: a real virtual microphone device

On macOS the soundboard can be routed into a loopback audio device so other
apps -- Zoom, Discord, a browser -- select it from their own input menus. macOS
has no command-line PCM feeder like Linux, so this writes the mix into the
device through the native `sound_cli` CoreAudio sink. Two one-time setup steps:

```sh
brew install blackhole-2ch                                   # the loopback device
cargo build --manifest-path sound/native/sound_cli/Cargo.toml # the native sink
```

`BlackHole 2ch` is a maintained, signed/notarized loopback (an external system
component you install once, like the PipeWire tools on Linux -- not a bundled
dependency). Then:

```dart
import 'package:soundboard/soundboard.dart';
import 'package:soundboard/coreaudio.dart';

const fmt = CaptureFormat(sampleRate: 48000, channels: 2);
final board = Soundboard(format: fmt);

final recording = await board.asMicrophoneBackend().startRecording(format: fmt);
final vmic = await CoreAudioVirtualMic.create(format: fmt); // BlackHole 2ch
await vmic.feed(recording.frames); // stream mic + clips into the device

// ... board.play(clip) ... the app hears it on the "BlackHole 2ch" mic ...

await vmic.dispose();
```

`CoreAudioVirtualMic.isSupported()` checks macOS, the native library, and the
device first (it never throws). The native sink converts the mix's S16LE to the
device's Float32 and up-mixes mono to stereo. See `example/macos_virtual_mic.dart`
(`dart run example/macos_virtual_mic.dart`). An own-brand "Soundboard" device
(a signed, notarized CoreAudio driver) is the next step.

## Limitations (Phase 1)

- Clips are not resampled: a clip should be at the soundboard's `format` sample
  rate (channel count is adapted automatically). Resampling is future work.
- This is an in-process mixer. Exposing the mix as an OS-level virtual
  microphone device selectable by other apps is future work.

## License

MIT.
