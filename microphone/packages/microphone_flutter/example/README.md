# microphone_flutter_example

Demonstrates `microphone_flutter`: record from the microphone, watch a
live input-level meter, and stop to keep the captured WAV in memory.

## Running

```sh
flutter run -d macos    # also: -d <ios device>, -d chrome, an Android emulator
```

The first recording prompts for microphone permission. The required platform
configuration is already in this example: `NSMicrophoneUsageDescription` and the
audio-input entitlement on macOS/iOS, and `RECORD_AUDIO` on Android.
