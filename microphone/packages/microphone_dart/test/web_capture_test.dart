@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:microphone_dart/microphone_dart.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

// Runs against Chrome's fake capture device (see dart_test.yaml):
//   dart test -p chrome
void main() {
  setUp(Microphone.reset);
  tearDown(Microphone.reset);

  test('the web backend is selected by default', () {
    expect(Microphone.backend.name, 'web');
  });

  test('records a clip and returns a well-formed WAV', () async {
    final recording = await Microphone.record();
    final chunks = <int>[];
    recording.frames.listen((c) => chunks.add(c.length));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final wav = await recording.stop();
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(wav.length, greaterThan(44));
    expect(chunks, isNotEmpty);
    expect(recording.duration, greaterThan(Duration.zero));
    await recording.dispose();
  });

  test('captures through an AudioWorklet in ~20 ms batches', () async {
    final recording = await Microphone.record();
    final sizes = <int>[];
    recording.frames.listen((c) => sizes.add(c.length));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await recording.stop();
    final batch = 2 * (recording.format.sampleRate / 50).round();
    expect(sizes, isNotEmpty);
    expect(sizes.every((n) => n <= batch), isTrue, reason: '$sizes');
    expect(sizes.where((n) => n == batch), isNotEmpty);
    await recording.dispose();
  });

  test('falls back to a ScriptProcessor without AudioWorklet', () async {
    // Hide BaseAudioContext.prototype.audioWorklet for this test.
    final object = globalContext['Object'] as JSObject;
    final prototype =
        (globalContext['BaseAudioContext'] as JSObject)['prototype']
            as JSObject;
    final descriptor = object.callMethod<JSObject>(
      'getOwnPropertyDescriptor'.toJS,
      prototype,
      'audioWorklet'.toJS,
    );
    prototype.delete('audioWorklet'.toJS);
    addTearDown(
      () => object.callMethod<JSAny?>(
        'defineProperty'.toJS,
        prototype,
        'audioWorklet'.toJS,
        descriptor,
      ),
    );

    final recording = await Microphone.record();
    final sizes = <int>[];
    recording.frames.listen((c) => sizes.add(c.length));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await recording.stop();
    expect(sizes, isNotEmpty);
    expect(sizes.every((n) => n == 4096 * 2), isTrue, reason: '$sizes');
    await recording.dispose();
  });

  test('pause drops audio and resume continues', () async {
    final recording = await Microphone.record();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await recording.pause();
    final atPause = recording.pcm.length;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(recording.pcm.length, atPause);
    await recording.resume();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(recording.pcm.length, greaterThan(atPause));
    await recording.stop();
    await recording.dispose();
  });

  test('stop then dispose tears down cleanly', () async {
    var rejections = 0;
    final onRejection = ((web.Event _) => rejections++).toJS;
    web.window.addEventListener('unhandledrejection', onRejection);
    addTearDown(
      () => web.window.removeEventListener('unhandledrejection', onRejection),
    );
    final recording = await Microphone.record();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await recording.stop();
    await recording.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(rejections, 0);
  });

  test('a Web Audio setup failure releases the microphone', () async {
    final opened = _spyOnGetUserMedia();
    final audioContext = globalContext['AudioContext'];
    JSObject failingAudioContext() => throw StateError('no audio');
    globalContext['AudioContext'] = failingAudioContext.toJS;
    addTearDown(() => globalContext['AudioContext'] = audioContext);

    await expectLater(Microphone.record(), throwsA(isA<CaptureException>()));
    final tracks = opened.single.getTracks().toDart;
    expect(tracks, isNotEmpty);
    expect(tracks.every((t) => t.readyState == 'ended'), isTrue);
  });

  test('a track that ends on its own ends the recording', () async {
    final opened = _spyOnGetUserMedia();
    final recording = await Microphone.record();
    Object? error;
    var closed = false;
    recording.frames.listen(
      null,
      onError: (Object e) => error = e,
      onDone: () => closed = true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // What the browser does when the input is unplugged or access revoked.
    opened.single.getTracks().toDart.first.dispatchEvent(web.Event('ended'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(error, isA<CaptureException>());
    expect(closed, isTrue);
    expect(recording.state, RecordingState.stopped);
    expect((await recording.stop()).length, greaterThan(44));
    await recording.dispose();
  });

  test('an unknown deviceId fails rather than using another input', () async {
    await expectLater(
      Microphone.record(deviceId: 'no-such-device'),
      throwsA(
        isA<CaptureException>().having(
          (e) => e.message,
          'message',
          contains('OverconstrainedError'),
        ),
      ),
    );
  });

  test('lists audio inputs', () async {
    expect(await Microphone.requestPermission(), isTrue);
    final devices = await Microphone.devices();
    expect(devices, isNotEmpty);
    expect(devices.every((d) => d.id.isNotEmpty), isTrue);
  });
}

/// Records every stream getUserMedia hands out for the rest of the test.
List<web.MediaStream> _spyOnGetUserMedia() {
  final mediaDevices = web.window.navigator.mediaDevices as JSObject;
  final getUserMedia = mediaDevices['getUserMedia'] as JSFunction;
  final opened = <web.MediaStream>[];
  mediaDevices['getUserMedia'] = ((JSAny? constraints) {
    final promise =
        getUserMedia.callAsFunction(mediaDevices, constraints)
            as JSPromise<web.MediaStream>;
    return promise.toDart.then((stream) {
      opened.add(stream);
      return stream;
    }).toJS;
  }).toJS;
  addTearDown(() => mediaDevices.delete('getUserMedia'.toJS));
  return opened;
}
