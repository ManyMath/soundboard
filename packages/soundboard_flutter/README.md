# soundboard_flutter

Flutter integration for the pure-Dart `soundboard` package.

This companion package re-exports Soundboard, depends on the native
`sound_flutter` and `microphone_flutter` build plugins, initializes both
backends, and loads clips from Flutter assets. Import
`package:soundboard_flutter/desktop.dart` when using the macOS, Windows, or
Linux virtual-microphone adapters.

```dart
import 'package:soundboard_flutter/soundboard_flutter.dart';

await SoundboardFlutter.ensureInitialized();
final board = Soundboard();
final clip = await SoundboardFlutter.loadAsset(board, 'assets/chime.wav');
final voice = await board.play(clip);
```

The underlying `soundboard` and `mixer_dart` packages do not depend on Flutter.
