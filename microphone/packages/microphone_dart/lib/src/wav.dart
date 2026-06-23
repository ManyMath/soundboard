import 'dart:typed_data';

import 'capture_format.dart';

/// Wraps raw interleaved PCM [pcm] in a canonical 44-byte WAV (RIFF) header.
///
/// [format] must match how the PCM was captured. Only [SampleFormat.int16] is
/// supported, so the header is always 16-bit integer PCM.
Uint8List wavFromPcm(Uint8List pcm, CaptureFormat format) {
  assert(
    format.sampleFormat == SampleFormat.int16,
    'only int16 PCM is supported',
  );
  final bitsPerSample = format.sampleFormat.bytesPerSample * 8;
  final blockAlign = format.bytesPerFrame;
  final byteRate = format.bytesPerSecond;
  final dataBytes = pcm.length;

  final out = Uint8List(44 + dataBytes);
  final view = ByteData.sublistView(out);
  var o = 0;

  void ascii(String s) {
    for (final c in s.codeUnits) {
      out[o++] = c;
    }
  }

  void u32(int v) {
    view.setUint32(o, v, Endian.little);
    o += 4;
  }

  void u16(int v) {
    view.setUint16(o, v, Endian.little);
    o += 2;
  }

  ascii('RIFF');
  u32(36 + dataBytes); // file size minus the 8-byte RIFF/size prefix
  ascii('WAVE');
  ascii('fmt ');
  u32(16); // PCM fmt chunk size
  u16(1); // audio format: PCM
  u16(format.channels);
  u32(format.sampleRate);
  u32(byteRate);
  u16(blockAlign);
  u16(bitsPerSample);
  ascii('data');
  u32(dataBytes);
  out.setRange(44, 44 + dataBytes, pcm);
  return out;
}
