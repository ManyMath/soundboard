// Web example for `microphone_dart`. Records from the browser microphone via
// the WebCaptureBackend and offers the captured WAV as a download.
//
// Build and serve:
//   ./packages/microphone_dart/example/serve_web.sh
// then open the printed URL and click "Record" (a user gesture is required
// before the browser will grant microphone access).

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart';
import 'package:web/web.dart' as web;

Recording? _recording;

void main() {
  final status = web.document.getElementById('status')!;
  final recordBtn =
      web.document.getElementById('record')! as web.HTMLButtonElement;
  final stopBtn = web.document.getElementById('stop')! as web.HTMLButtonElement;

  status.textContent = 'Backend: ${Microphone.backend.name}';
  stopBtn.disabled = true;

  recordBtn.onclick = (web.Event _) {
    _start(status, recordBtn, stopBtn);
  }.toJS;

  stopBtn.onclick = (web.Event _) {
    _stop(status, recordBtn, stopBtn);
  }.toJS;
}

Future<void> _start(
  web.Element status,
  web.HTMLButtonElement recordBtn,
  web.HTMLButtonElement stopBtn,
) async {
  // Disable Record across the permission prompt so a second click cannot
  // start a recording that nothing would stop.
  recordBtn.disabled = true;
  try {
    final recording = await Microphone.record();
    _recording = recording;
    status.textContent = 'Recording at ${recording.format.sampleRate} Hz...';
    stopBtn.disabled = false;
  } on Object catch (e) {
    status.textContent = 'Error: $e';
    recordBtn.disabled = false;
  }
}

Future<void> _stop(
  web.Element status,
  web.HTMLButtonElement recordBtn,
  web.HTMLButtonElement stopBtn,
) async {
  final recording = _recording;
  if (recording == null) return;
  _recording = null;
  stopBtn.disabled = true;
  final wav = await recording.stop();
  await recording.dispose();
  recordBtn.disabled = false;
  stopBtn.disabled = true;
  status.textContent =
      'Recorded ${recording.duration.inMilliseconds} ms (${wav.length} bytes).';
  _offerDownload(wav);
}

/// Triggers a browser download of [wav] as recording.wav.
void _offerDownload(Uint8List wav) {
  final parts = <JSUint8Array>[wav.toJS].toJS as JSArray<web.BlobPart>;
  final blob = web.Blob(parts, web.BlobPropertyBag(type: 'audio/wav'));
  final url = web.URL.createObjectURL(blob);
  (web.document.createElement('a') as web.HTMLAnchorElement)
    ..href = url
    ..download = 'recording.wav'
    ..click();
  // Revoking right away can cancel the download before it starts.
  Timer(const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
}
