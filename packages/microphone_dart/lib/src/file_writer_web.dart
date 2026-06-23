import 'dart:typed_data';

/// The web has no file system; recording-to-file is unsupported there. Use the
/// WAV bytes from `Recording.stop` instead.
Future<void> writeBytes(String path, Uint8List bytes) async {
  throw UnsupportedError(
    'Writing to a file is not supported on the web; use Recording.stop to get '
    'the WAV bytes and save them yourself (e.g. via a download).',
  );
}
