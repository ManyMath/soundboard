import 'dart:typed_data';

/// Re-cuts a stream of S16LE byte chunks on whole-sample boundaries.
///
/// A producer may split its stream anywhere, including mid-sample. Passing
/// such a chunk on would shift every later sample by a byte, so a trailing odd
/// byte is held back and joined to the front of the next chunk.
class SampleAligner {
  int? _pending;

  /// Returns the whole samples available once [chunk] arrives (possibly none).
  Uint8List align(Uint8List chunk) {
    final pending = _pending;
    if (pending == null && chunk.length.isEven) return chunk;
    final joined = pending == null
        ? chunk
        : (Uint8List(chunk.length + 1)
            ..[0] = pending
            ..setRange(1, chunk.length + 1, chunk));
    final whole = joined.length & ~1;
    _pending = whole < joined.length ? joined[whole] : null;
    return Uint8List.sublistView(joined, 0, whole);
  }
}
