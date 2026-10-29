import 'dart:async';
import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart' as mic;
import 'package:sound_dart/sound_dart.dart' as sound;
import 'package:soundboard/soundboard.dart';
import 'package:test/test.dart';

class SessionMic extends mic.StreamCaptureBackend
    implements mic.AudioSessionCaptureBackend {
  SessionMic(Stream<Uint8List> source)
    : super(source: source, format: const CaptureFormat(sampleRate: 8000));
  mic.AudioSessionManagement? receivedMode;
  @override
  Future<Recording> startRecordingWithAudioSession({
    required mic.AudioSessionManagement audioSessionManagement,
    CaptureFormat format = const CaptureFormat(),
    String? deviceId,
    bool retainPcm = true,
  }) {
    receivedMode = audioSessionManagement;
    return super.startRecording(
      format: format,
      deviceId: deviceId,
      retainPcm: retainPcm,
    );
  }
}

void main() {
  const format = CaptureFormat(sampleRate: 8000);
  tearDown(sound.Sound.reset);

  test('playback continues after application-managed capture stops', () async {
    final speaker = sound.SilentBackend(
      simulatedDuration: const Duration(seconds: 10),
    );
    sound.Sound.registerBackend(speaker, makeActive: true);
    final input = StreamController<Uint8List>();
    final physical = SessionMic(input.stream);
    final board = Soundboard(format: format);
    addTearDown(board.dispose);
    final capture = await board
        .asMicrophoneBackend(
          physicalMic: physical,
          audioSessionManagement: AudioSessionManagement.application,
        )
        .startRecording(retainPcm: false);
    final frames = <Uint8List>[];
    final sub = capture.frames.listen(frames.add);
    final voice = await board.play(
      board.loadBytes(Uint8List(320), format: format),
    );
    expect(physical.receivedMode, AudioSessionManagement.application);
    expect(voice.isPlaying, isTrue);
    input.add(Uint8List(320));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(frames, isNotEmpty);
    await capture.stop();
    expect(voice.isPlaying, isTrue);
    await sub.cancel();
    await input.close();
  });

  test('stopping playback leaves capture running', () async {
    sound.Sound.registerBackend(
      sound.SilentBackend(simulatedDuration: const Duration(seconds: 10)),
      makeActive: true,
    );
    final input = StreamController<Uint8List>();
    final physical = SessionMic(input.stream);
    final board = Soundboard(format: format);
    addTearDown(board.dispose);
    final capture = await board
        .asMicrophoneBackend(
          physicalMic: physical,
          audioSessionManagement: AudioSessionManagement.application,
        )
        .startRecording();
    await board.play(board.loadBytes(Uint8List(320), format: format));
    await board.stopAll();
    expect(capture.isRecording, isTrue);
    input.add(Uint8List(320));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(capture.pcm, isNotEmpty);
    await capture.stop();
    await input.close();
  });

  test(
    'unsupported physical backend never silently uses automatic session',
    () async {
      final physical = mic.SilentBackend();
      final board = Soundboard(format: format);
      addTearDown(board.dispose);
      await expectLater(
        board
            .asMicrophoneBackend(
              physicalMic: physical,
              audioSessionManagement: AudioSessionManagement.application,
            )
            .startRecording(),
        throwsUnsupportedError,
      );
      expect(physical.started, isEmpty);
    },
  );
}
