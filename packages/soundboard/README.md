# soundboard

Pure-Dart soundboard playback and microphone mixing.

`soundboard` composes three framework-independent packages:

- `sound_dart` decodes clips and plays ordinary speaker audio.
- `mixer_dart` resamples, channel-adapts, and mixes independently controlled
  clip voices.
- `microphone_dart` captures the physical microphone and exposes the combined
  stream as a `CaptureBackend`.

There is no Flutter dependency in this package. Flutter applications should use
the companion `soundboard_flutter` package, which supplies native builds,
initialization, and asset helpers.

## Playback and mixing

```dart
import 'package:soundboard/soundboard.dart';

final board = Soundboard(
  format: const CaptureFormat(sampleRate: 48000, channels: 2),
);
final applause = await board.loadFile('applause.wav');

// The default sends the clip to both speakers and the microphone mix.
final voice = await board.play(applause, gain: 0.8);
await voice.setLooping(true);
await voice.pause();
await voice.seek(const Duration(milliseconds: 250));
await voice.resume();

// Route a trigger into the microphone mix without local monitoring.
await board.play(
  applause,
  outputs: const {SoundboardOutput.microphone},
);

final mixed = board.asMicrophoneBackend();
final recording = await mixed.startRecording(retainPcm: false);
```

`SoundboardVoice` also supports per-trigger gain, stop, disposal, position,
duration, and natural-completion notification. `Soundboard.masterVolume`
applies live to both routes, while `micVolume` controls only the physical input.

## System-visible virtual microphones

The separate platform entry points implement `VirtualMicrophone`:

- `package:soundboard/pipewire.dart`: Linux PipeWire virtual source.
- `package:soundboard/coreaudio.dart`: macOS BlackHole/CoreAudio feeder.
- `package:soundboard/windows.dart`: Windows VB-CABLE/WinMM feeder.

```dart
final recording = await board
    .asMicrophoneBackend()
    .startRecording(retainPcm: false);
final virtualMic = await PipeWireVirtualMic.create(format: board.format);
unawaited(virtualMic.feed(recording.frames));
```

macOS users install BlackHole; Windows users install VB-CABLE and select
`CABLE Output` in Discord, games, or another microphone-consuming app. Linux
uses the tools supplied with PipeWire.

## License

MIT.
