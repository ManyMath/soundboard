# `microphone_dart`

Cross-platform microphone recording for Dart and Flutter with the goal of no 
system dependencies that need to be installed.  Pure Dart (works in CLI tools) 
with native microphone capture over FFI.

For Flutter apps, see the `microphone_flutter` package, which builds the native 
library for you via cargokit and should 'just work'.

The only build-time requirement beyond Dart/Flutter is Rust.  That may be 
worked-around with precompiled binaries (TODO).

## Native library

Outside Flutter, build the `microphone` Rust crate yourself. Its source ships
in the `microphone_flutter` package's `rust/` directory (in this repository,
`packages/microphone_flutter/rust`):

```sh
cargo build --release --manifest-path packages/microphone_flutter/rust/Cargo.toml
```

Run from the repository, `microphone_dart` finds that build by itself;
elsewhere, point the `MICROPHONE_LIB` environment variable at the library
(`libmicrophone.so`, `libmicrophone.dylib` or `microphone.dll`). Without it,
`Microphone` falls back to a backend that records silence.
