# microphone

Cross-platform microphone recording for Dart and Flutter with the goal of no 
additional system dependencies for users or devs to install.  The only build-
time requirement beyond Dart/Flutter is Rust, and eventually that will be 
obviated via precompiled binaries (TODO).

This is a [melos](https://melos.invertase.dev) monorepo:

| Package | What it is |
|---|---|
| [`packages/microphone_dart`](packages/microphone_dart) | Pure Dart (no Flutter); works in CLI tools. Reaches native microphone recording over `dart:ffi`. |
| [`packages/microphone_flutter`](packages/microphone_flutter) | Flutter plugin. Builds the native library automatically (via cargokit) and re-exports the `microphone_dart` API. |
| [`native/microphone`](native/microphone) | Rust crate. |

## Status

| Host | Status |
|---|---|
| Android | Working |
| iOS | Working |
| macOS | Working |
| Ubuntu 24.04 | Working |
| Web | Working |
| Windows 11 | Working |

Web tested on macOS in Chrome and Safari, Ubuntu 24.04 in Chrome and Firefox, and Windows 11 in Chrome and Edge.

## Development

Driven by [melos](https://melos.invertase.dev) (config lives in the root
`pubspec.yaml`). After `dart pub get` (or `flutter pub get`):

```sh
dart run melos run native:build   # build the Rust shared library
dart run melos run analyze        # analyze microphone_dart + microphone_flutter
dart run melos run format         # check Dart formatting (format:fix to apply)
dart run melos run test           # Dart + Flutter tests
dart run melos run native:test    # Rust crate tests
```
