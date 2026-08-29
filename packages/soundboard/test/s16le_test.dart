import 'dart:typed_data';

import 'package:soundboard/src/s16le.dart';
import 'package:test/test.dart';

Uint8List bytesOf(List<int> samples) {
  final out = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return out;
}

void main() {
  test('decodes every sample of an aligned chunk', () {
    expect(s16leSamples(bytesOf([1, -2, 300, -32768])), [1, -2, 300, -32768]);
  });

  test('decodes a chunk that starts at an odd byte offset', () {
    final backing = Uint8List(9)..setAll(1, bytesOf([7, -8, 9, -10]));
    final chunk = Uint8List.sublistView(backing, 1);
    expect(s16leSamples(chunk), [7, -8, 9, -10]);
  });

  test('ignores a trailing odd byte', () {
    final chunk = Uint8List.fromList([
      ...bytesOf([5, 6]),
      0x7f,
    ]);
    expect(s16leSamples(chunk), [5, 6]);
  });
}
