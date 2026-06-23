import 'dart:typed_data';

// Writes a file with dart:io on native platforms and throws on the web, where
// there is no file system. The conditional import keeps dart:io out of web
// builds entirely.
import 'file_writer_io.dart'
    if (dart.library.js_interop) 'file_writer_web.dart'
    as impl;

/// Writes [bytes] to [path]. Throws [UnsupportedError] on the web.
Future<void> writeBytes(String path, Uint8List bytes) =>
    impl.writeBytes(path, bytes);
