import 'dart:typed_data';

/// Decodes the whole samples in interleaved S16LE [bytes]; a trailing odd
/// byte is ignored.
Int16List s16leSamples(Uint8List bytes) {
  final samples = Int16List(bytes.length ~/ 2);
  if (Endian.host == Endian.little && bytes.offsetInBytes.isEven) {
    // sublistView counts the range in elements of [bytes], i.e. in bytes.
    samples.setAll(0, Int16List.sublistView(bytes, 0, samples.length * 2));
  } else {
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little);
    }
  }
  return samples;
}

/// Regroups arbitrarily split S16LE byte chunks into whole interleaved
/// frames, carrying a partial frame over to the next chunk.
final class S16leFrames {
  S16leFrames(int channels) : _frameBytes = channels * 2;

  final int _frameBytes;
  Uint8List _carry = Uint8List(0);

  /// The samples of every whole frame available once [chunk] is appended.
  Int16List take(Uint8List chunk) {
    var bytes = chunk;
    if (_carry.isNotEmpty) {
      bytes = Uint8List(_carry.length + chunk.length)
        ..setAll(0, _carry)
        ..setAll(_carry.length, chunk);
    }
    final whole = bytes.length - bytes.length % _frameBytes;
    _carry = Uint8List.fromList(Uint8List.sublistView(bytes, whole));
    return s16leSamples(Uint8List.sublistView(bytes, 0, whole));
  }
}
