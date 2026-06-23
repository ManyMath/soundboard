import 'dart:io';
import 'dart:typed_data';

/// Writes [bytes] to [path] on disk.
Future<void> writeBytes(String path, Uint8List bytes) =>
    File(path).writeAsBytes(bytes, flush: true);
