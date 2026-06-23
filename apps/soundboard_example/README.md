# soundboard_example

A Flutter app that demonstrates the `soundboard` package's OS-level virtual
microphone: it publishes a microphone device other apps (Zoom, Discord, a
browser) can select, plays test tones into it, and mixes a chosen physical
microphone into the mix.

- **macOS** routes the mix into the BlackHole loopback device via CoreAudio.
- **Linux** publishes a PipeWire virtual source.

The `*_flutter` plugins build the native Rust libraries (`libsound_cli`,
`libmicrophone`) via cargokit and bundle them into the app, so no separate
`cargo build` is needed.

## Setup

### macOS

```sh
brew install blackhole-2ch        # the loopback device
sudo killall coreaudiod           # reload audio so it appears (or reboot)
```

### Linux

Have a running PipeWire session with `pw-loopback` and `pw-cat` (the `pipewire`
package). No driver install needed.

## Run

```sh
flutter run -d macos      # or: flutter run -d linux
```

Then:

1. Press **Go live** (grant the microphone permission prompt). The status card
   shows the live device name -- "BlackHole 2ch" on macOS, "Soundboard" on
   Linux.
2. In any other app, select that device as the microphone.
3. Press **Beep** or **Chord** to mix a tone into it, and pick a physical
   microphone from the dropdown to mix your voice in too. The sliders set the
   clip and microphone volumes.

This app is intentionally not a member of the repo's pure-Dart pub workspace (a
workspace cannot include Flutter packages); it uses path dependencies and
`dependency_overrides` to pin the vendored `sound_dart`/`microphone_dart`.
