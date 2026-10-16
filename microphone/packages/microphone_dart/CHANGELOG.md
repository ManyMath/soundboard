# Changelog

## 0.0.2

- Permission: `requestPermission()` now shows the system prompt on macOS and
  iOS (and on Android through `microphone_flutter`), `hasPermission()` reports
  the real state, and `record()` asks first when permission is missing,
  throwing `PermissionDeniedException` if refused. Previously the FFI backend
  always claimed permission, so a denied app recorded silence. New
  `NativePlatform` hooks in `package:microphone_dart/platform_hooks.dart`
  (not exported from the main library) let a platform integration supply
  permission and the device list where the native library cannot.
- Web: capture runs on an AudioWorklet (off the main thread, ~20 ms batches),
  with ScriptProcessor as the fallback; paused audio can no longer leak in after
  `resume()`.
- `StreamCaptureBackend` presents an injected PCM stream as a capture source,
  and `MixingCaptureBackend` sums several sources into one recording, clocked
  by a primary source.
- `retainPcm: false` on `Microphone.record` / `CaptureBackend.startRecording`
  keeps open-ended live recordings from accumulating PCM without bound.
- A backend pinned with `makeActive` / `useBackend` now survives later
  registrations.
- Device selection: Linux lists ALSA capture devices (`default` first, then
  each card's input PCMs) and Android lists `AudioManager` inputs (through
  `microphone_flutter`); `record(deviceId: ...)` captures from the selected one
  on both, failing rather than falling back if it is unavailable. Windows
  reports full device names (no longer cut at 31 characters) and flags the
  input Windows actually records from as the default.
- FFI backend fixes:
  - `stop()` no longer drops audio queued while the isolate was busy (only the
    first 16384 samples of the backlog were kept).
  - `stop()` now releases the native capture; previously the device stayed
    open, buffering natively, until `dispose()`.
  - Disposing the backend stops its live recordings first.
  - Native capture errors are reported with the right message, and reads are
    whole frames.
- Native library fixes: ALSA and AAudio read errors (e.g. an Android route
  change) end the recording with an error instead of silence; ALSA recovers
  from overruns and stops without stalling the isolate; CoreAudio start fails
  if a buffer cannot be queued; waveIn buffers are serviced on a capture
  thread instead of the driver callback, and teardown releases all of them; on
  iOS, playback stays on the speaker (or Bluetooth headphones) while capturing.
- Mixing: a source that fails to start no longer leaves the others running,
  and `stop()` keeps the primary's final chunk.
- Web backend fixes: a selected `deviceId` is required exactly; only a refused
  prompt raises `PermissionDeniedException` (other getUserMedia failures raise
  `CaptureException`); stop-then-dispose no longer closes the AudioContext
  twice; a failed Web Audio setup releases the microphone; a track ended by the
  browser ends the recording with an error.
- `AudioLevel.fromPcm` accepts chunks at odd byte offsets.
- `wavFromPcm` throws `MicrophoneException` for PCM over the 4 GiB WAV limit
  instead of writing a truncated size, and pads odd-sized data to an even
  chunk.
- `StreamCaptureBackend` and `MixingCaptureBackend` stay sample-aligned when a
  source cuts a chunk mid-sample, instead of shifting every later sample by a
  byte.

## 0.0.1

- Initial scaffolding.
- Core API: `Microphone`, `CaptureFormat`, `Recording`, pluggable
  `CaptureBackend`s.
- `Recording` exposes both a live PCM `frames` stream and `stop`, which returns
  the capture as WAV (RIFF) bytes; `stopToFile` writes a WAV on native
  platforms.
- Pure-Dart WAV writer (`wavFromPcm`); captured audio is S16LE PCM.
- `SilentBackend` fallback that captures silence, so the API and tests run
  without a microphone. Web-safe via conditional imports.
- FFI backend that captures via the native `microphone` Rust library, draining
  S16LE PCM into the `frames` stream and an accumulating buffer. Capture works
  on macOS and iOS (CoreAudio AudioQueue input), Android (AAudio input),
  Windows (waveIn) and Linux (ALSA).
- Web capture backend (getUserMedia + Web Audio).
- `AudioLevel` (RMS/peak, with dBFS) and a `Recording.levels()` stream for live
  input metering.
- Native pause/resume that drops audio captured while paused (no silent gap).
- Input device enumeration (`Microphone.devices()`, `CaptureDevice`) and
  selection (`record(deviceId: ...)`). macOS lists/selects via CoreAudio,
  Windows via waveIn, and the web via getUserMedia/enumerateDevices.
- Configurable sample rate / channels honored where the platform supports it
  (macOS verified for 8/16/44.1/48 kHz, mono and stereo); resample policy
  documented on `CaptureFormat`.
- `Microphone.permissionDelegate` (`MicrophonePermissionDelegate`) lets a host
  supply platform permission checks to the FFI backend, which otherwise
  reports permission as granted. `microphone_flutter` uses it for Android's
  runtime `RECORD_AUDIO` permission.
