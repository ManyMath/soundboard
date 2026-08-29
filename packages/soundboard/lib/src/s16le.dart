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
