# sound_flutter

Flutter integration for [`sound_dart`](../sound_dart): cross-platform audio 
with no system dependencies for users or devs to install.

This package builds the shared `sound_cli` Rust crate automatically (via
[cargokit](https://github.com/ManyMath/cargokit)) and bundles it with your app,
then re-exports the full `sound_dart` API.

```dart
import 'package:sound_flutter/sound_flutter.dart';

await SoundFlutter.ensureInitialized();
final playback = await Sound.playFile('/path/to/chime.wav');
await playback.onComplete;
```

Building requires Rust (`rustup`). Precompiled binaries are not configured
in this copy: the crate differs from upstream, so no published binary could
match its hash. To offer them, add a `native/sound_cli/cargokit.yaml` with a
`precompiled_binaries` `url_prefix` and the public key from
`dart run build_tool gen-key`, and publish signed `precompiled_<crate-hash>`
releases there.


