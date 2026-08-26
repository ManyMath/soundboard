import 'dart:async';
import 'dart:typed_data';

import 'package:soundboard/soundboard.dart';
import 'package:sound_dart/sound_dart.dart'
    show
        Playback,
        PlaybackState,
        SilentBackend,
        SilentPlayback,
        Sound,
        SoundSource;
import 'package:test/test.dart';

/// Builds interleaved S16LE bytes from signed sample values.
Uint8List pcm16(List<int> samples) {
  final out = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return out;
}

/// Reads interleaved S16LE bytes back into signed sample values.
List<int> samples16(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  return [
    for (var i = 0; i < bytes.length ~/ 2; i++)
      view.getInt16(i * 2, Endian.little),
  ];
}

const _fmt = CaptureFormat(sampleRate: 8000, channels: 1);

/// Long enough for the clip bus (20 ms ticks) to fully buffer a short clip.
Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 150));
Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  group('Clip loading', () {
    test('loadBytes wraps raw PCM with its format', () {
      final board = Soundboard(format: _fmt);
      final clip = board.loadBytes(pcm16([1, 2, 3, 4]), format: _fmt);
      expect(clip.channels, 1);
      expect(clip.sampleRate, 8000);
      expect(clip.frameCount, 4);
      expect(samples16(clip.samples.buffer.asUint8List()), [1, 2, 3, 4]);
    });

    test('loadFile decodes through the active sound backend', () async {
      // Pin a silent sound backend so the decode path needs no hardware.
      Sound.registerBackend(
        SilentBackend(
          simulatedDuration: const Duration(milliseconds: 100),
          pcmSampleRate: 8000,
          pcmChannels: 1,
        ),
        makeActive: true,
      );
      addTearDown(Sound.reset);
      final board = Soundboard(format: _fmt);
      final clip = await board.loadFile('whatever.wav');
      expect(clip.sampleRate, 8000);
      expect(clip.frameCount, 800); // 0.1 s at 8 kHz
      expect(clip.samples.every((v) => v == 0), isTrue);
    });

    test('loadFile fails loudly when nothing can decode', () async {
      // The silent fallback that stands in for a missing decoder.
      Sound.registerBackend(SilentBackend(), makeActive: true);
      addTearDown(Sound.reset);
      final board = Soundboard(format: _fmt);

      await expectLater(
        board.loadFile('whatever.wav'),
        throwsA(isA<UnsupportedSourceException>()),
      );
    });
  });

  group('playback routing and controls', () {
    late SilentBackend sound;

    setUp(() {
      sound = SilentBackend(simulatedDuration: const Duration(seconds: 1));
      Sound.registerBackend(sound, makeActive: true);
    });

    tearDown(Sound.reset);

    test('speaker-only playback uses sound_dart and returns a voice', () async {
      final board = Soundboard(format: _fmt);
      addTearDown(board.dispose);
      final clip = board.loadBytes(pcm16([100, 200]), format: _fmt);

      final voice = await board.play(
        clip,
        outputs: const {SoundboardOutput.speakers},
      );

      expect(sound.loaded, hasLength(1));
      expect(voice.isPlaying, isTrue);
      await voice.pause();
      expect(voice.isPlaying, isFalse);
      await voice.seek(Duration.zero);
      await voice.setGain(0.5);
      await voice.setLooping(true);
      await voice.resume();
      expect(voice.isPlaying, isTrue);
      await voice.stop();
      expect(voice.isPlaying, isFalse);
    });

    test('microphone-only playback resamples onto the board clock', () async {
      const source = CaptureFormat(sampleRate: 2, channels: 1);
      const output = CaptureFormat(sampleRate: 4, channels: 1);
      final board = Soundboard(
        format: output,
        chunk: const Duration(seconds: 1),
      );
      addTearDown(board.dispose);
      final nextChunk = board.mixedFrames.first;

      await board.play(
        board.loadBytes(pcm16([0, 1000, 2000]), format: source),
        outputs: const {SoundboardOutput.microphone},
      );

      expect(samples16(await nextChunk), [0, 500, 1000, 1500]);
      expect(sound.loaded, isEmpty);
    });

    test('default routing sends one trigger to both destinations', () async {
      final board = Soundboard(
        format: _fmt,
        chunk: const Duration(milliseconds: 20),
      );
      addTearDown(board.dispose);
      final nextChunk = board.mixedFrames.first;

      await board.play(
        board.loadBytes(pcm16(List<int>.filled(160, 400)), format: _fmt),
      );

      expect(sound.loaded, hasLength(1));
      expect(samples16(await nextChunk), List<int>.filled(160, 400));
    });
  });

  group('lifecycle races', () {
    tearDown(Sound.reset);

    test('dispose() during an in-flight play() releases the speaker', () async {
      final gate = Completer<void>();
      final sound = _GatedSilentBackend(gate.future);
      Sound.registerBackend(sound, makeActive: true);
      final board = Soundboard(format: _fmt);
      final clip = board.loadBytes(pcm16(List.filled(160, 1000)), format: _fmt);

      final pending = board.play(clip, looping: true);
      await board.dispose();
      gate.complete();
      final voice = await pending;

      expect(voice.isPlaying, isFalse);
      expect(sound.playbacks.single.state, PlaybackState.disposed);
    });

    test('stopAll() during an in-flight play() cancels it', () async {
      final gate = Completer<void>();
      final sound = _GatedSilentBackend(gate.future);
      Sound.registerBackend(sound, makeActive: true);
      final board = Soundboard(format: _fmt);
      addTearDown(board.dispose);
      final clip = board.loadBytes(pcm16(List.filled(160, 1000)), format: _fmt);

      final pending = board.play(clip, looping: true);
      await board.stopAll();
      gate.complete();

      expect((await pending).isPlaying, isFalse);
      expect(sound.playbacks.single.state, PlaybackState.disposed);
    });
  });

  test('a finished voice releases its speaker playback', () async {
    final sound = _GatedSilentBackend(
      Future<void>.value(),
      simulatedDuration: const Duration(milliseconds: 10),
    );
    Sound.registerBackend(sound, makeActive: true);
    addTearDown(Sound.reset);
    final board = Soundboard(format: _fmt);
    addTearDown(board.dispose);

    final voice = await board.play(
      board.loadBytes(pcm16([1, 2]), format: _fmt),
      outputs: const {SoundboardOutput.speakers},
    );
    await voice.onComplete;

    expect(sound.playbacks.single.state, PlaybackState.disposed);
  });

  test('stop() releases the speaker playback', () async {
    final sound = _GatedSilentBackend(Future<void>.value());
    Sound.registerBackend(sound, makeActive: true);
    addTearDown(Sound.reset);
    final board = Soundboard(format: _fmt);
    addTearDown(board.dispose);

    final voice = await board.play(
      board.loadBytes(pcm16([1, 2]), format: _fmt),
      outputs: const {SoundboardOutput.speakers},
    );
    await voice.stop();

    expect(sound.playbacks.single.state, PlaybackState.disposed);
  });

  test('a voice started during stopAll() stays tracked', () async {
    final stopGate = Completer<void>();
    final sound = _GatedSilentBackend(
      Future<void>.value(),
      stopGate: stopGate.future,
    );
    Sound.registerBackend(sound, makeActive: true);
    addTearDown(Sound.reset);
    final board = Soundboard(format: _fmt);
    final clip = board.loadBytes(pcm16([1, 2]), format: _fmt);
    const speakers = {SoundboardOutput.speakers};

    await board.play(clip, outputs: speakers);
    final stopping = board.stopAll(); // waits on the slow speaker stop
    final voice = await board.play(clip, outputs: speakers);
    stopGate.complete();
    await stopping;
    expect(voice.isPlaying, isTrue);

    await board.dispose();
    expect(sound.playbacks.last.state, PlaybackState.disposed);
  });

  test('a speaker route error reaches onComplete, not the zone', () async {
    final failure = Completer<void>();
    Sound.registerBackend(
      _FailingSilentBackend(failure.future),
      makeActive: true,
    );
    addTearDown(Sound.reset);
    final board = Soundboard(format: _fmt);
    addTearDown(board.dispose);
    final voice = await board.play(
      board.loadBytes(pcm16([1, 2]), format: _fmt),
      outputs: const {SoundboardOutput.speakers},
    );

    final completion = expectLater(voice.onComplete, throwsStateError);
    failure.completeError(StateError('native voice error'));
    await completion;
  });

  group('end-to-end mix (SilentBackend, no hardware)', () {
    // play() also routes to the speakers by default; keep those silent even
    // where the native sound library is built.
    setUp(() => Sound.registerBackend(SilentBackend(), makeActive: true));
    tearDown(Sound.reset);

    /// Starts a soundboard recording fed by a controllable physical mic.
    Future<(Soundboard, StreamController<Uint8List>, Recording)> start() async {
      final board = Soundboard(
        format: _fmt,
        chunk: const Duration(milliseconds: 20),
      );
      final micCtrl = StreamController<Uint8List>();
      final mic = StreamCaptureBackend(source: micCtrl.stream, format: _fmt);
      final backend = board.asMicrophoneBackend(physicalMic: mic);
      final rec = await backend.startRecording(format: _fmt);
      return (board, micCtrl, rec);
    }

    test(
      'yields the summed-and-clamped clip plus mic for a known input',
      () async {
        final (board, micCtrl, rec) = await start();
        board.play(
          board.loadBytes(pcm16(List.filled(320, 1000)), format: _fmt),
        );
        await settle(); // clip fully buffered on the clip bus
        micCtrl.add(pcm16(List.filled(320, 500)));
        await pump();

        final out = samples16(rec.pcm);
        expect(out.length, 320);
        expect(out.every((v) => v == 1500), isTrue); // 1000 clip + 500 mic
        await rec.stop();
        await micCtrl.close();
        await board.dispose();
      },
    );

    test('clamps the mix to the 16-bit range', () async {
      final (board, micCtrl, rec) = await start();
      board.play(board.loadBytes(pcm16(List.filled(160, 30000)), format: _fmt));
      await settle();
      micCtrl.add(pcm16(List.filled(160, 30000))); // 60000 -> clamps
      await pump();

      expect(samples16(rec.pcm).every((v) => v == 32767), isTrue);
      await rec.stop();
      await micCtrl.close();
      await board.dispose();
    });

    test('masterVolume scales clips and micVolume scales the mic', () async {
      final (board, micCtrl, rec) = await start();
      board.masterVolume = 0.5;
      board.micVolume = 0.5;
      board.play(board.loadBytes(pcm16(List.filled(160, 2000)), format: _fmt));
      await settle();
      micCtrl.add(pcm16(List.filled(160, 1000)));
      await pump();

      // clip 2000 * 0.5 = 1000; mic 1000 * 0.5 = 500; sum 1500.
      expect(samples16(rec.pcm).every((v) => v == 1500), isTrue);
      await rec.stop();
      await micCtrl.close();
      await board.dispose();
    });

    test('an extreme micVolume clamps instead of failing', () async {
      final (board, micCtrl, rec) = await start();
      board.micVolume = double.maxFinite;
      micCtrl.add(pcm16([1000, -1000]));
      await pump();

      expect(samples16(rec.pcm), [32767, -32768]);
      await rec.stop();
      await micCtrl.close();
      await board.dispose();
    });

    test(
      'a clip shorter than the mic mixes only where it has samples',
      () async {
        final (board, micCtrl, rec) = await start();
        board.play(
          board.loadBytes(pcm16(List.filled(160, 1000)), format: _fmt),
        );
        await settle();
        micCtrl.add(pcm16(List.filled(320, 500)));
        await pump();

        final out = samples16(rec.pcm);
        expect(out.length, 320);
        expect(out.sublist(0, 160).every((v) => v == 1500), isTrue);
        expect(out.sublist(160).every((v) => v == 500), isTrue); // mic only
        await rec.stop();
        await micCtrl.close();
        await board.dispose();
      },
    );

    test('stopAll removes clips so only the mic remains', () async {
      final (board, micCtrl, rec) = await start();
      board.play(board.loadBytes(pcm16(List.filled(800, 1000)), format: _fmt));
      board.stopAll(); // synchronous: no clip-bus tick has fired yet
      micCtrl.add(pcm16(List.filled(160, 500)));
      await pump();

      expect(samples16(rec.pcm).every((v) => v == 500), isTrue);
      await rec.stop();
      await micCtrl.close();
      await board.dispose();
    });

    test('rejects a mic that delivers a different format', () async {
      final board = Soundboard(format: _fmt);
      addTearDown(board.dispose);
      final micCtrl = StreamController<Uint8List>();
      addTearDown(micCtrl.close);
      final mic = StreamCaptureBackend(
        source: micCtrl.stream,
        format: const CaptureFormat(sampleRate: 48000, channels: 1),
      );

      await expectLater(
        board.asMicrophoneBackend(physicalMic: mic).startRecording(),
        throwsA(isA<CaptureException>()),
      );
    });

    test('with no clips the mic passes through unchanged', () async {
      final (board, micCtrl, rec) = await start();
      micCtrl.add(pcm16([10, 20, 30, 40]));
      await pump();

      expect(samples16(rec.pcm), [10, 20, 30, 40]);
      await rec.stop();
      await micCtrl.close();
      await board.dispose();
    });

    test('a mono clip up-mixes into a stereo board by duplication', () async {
      const stereo = CaptureFormat(sampleRate: 8000, channels: 2);
      const mono = CaptureFormat(sampleRate: 8000, channels: 1);
      final board = Soundboard(
        format: stereo,
        chunk: const Duration(milliseconds: 20),
      );
      final micCtrl = StreamController<Uint8List>();
      final mic = StreamCaptureBackend(source: micCtrl.stream, format: stereo);
      final rec = await board
          .asMicrophoneBackend(physicalMic: mic)
          .startRecording(format: stereo);

      // 160 mono frames of 1000 -> 160 stereo frames of (1000, 1000).
      board.play(board.loadBytes(pcm16(List.filled(160, 1000)), format: mono));
      await settle();
      micCtrl.add(pcm16(List.filled(320, 500))); // 160 stereo mic frames
      await pump();

      final out = samples16(rec.pcm);
      expect(out.length, 320);
      expect(out.every((v) => v == 1500), isTrue); // both channels get the sum
      await rec.stop();
      await micCtrl.close();
      await board.dispose();
    });

    test('a stereo clip down-mixes into a mono board by averaging', () async {
      const stereo = CaptureFormat(sampleRate: 8000, channels: 2);
      final (board, micCtrl, rec) = await start(); // mono board
      // 160 stereo frames of (1000, 3000) -> 160 mono samples of 2000.
      final interleaved = List<int>.generate(
        320,
        (i) => i.isEven ? 1000 : 3000,
      );
      board.play(board.loadBytes(pcm16(interleaved), format: stereo));
      await settle();
      micCtrl.add(pcm16(List.filled(160, 500)));
      await pump();

      expect(samples16(rec.pcm).every((v) => v == 2500), isTrue); // 2000 + 500
      await rec.stop();
      await micCtrl.close();
      await board.dispose();
    });

    test('retainPcm: false streams frames without accumulating pcm', () async {
      final board = Soundboard(
        format: _fmt,
        chunk: const Duration(milliseconds: 20),
      );
      final micCtrl = StreamController<Uint8List>();
      final mic = StreamCaptureBackend(source: micCtrl.stream, format: _fmt);
      final rec = await board
          .asMicrophoneBackend(physicalMic: mic)
          .startRecording(format: _fmt, retainPcm: false);

      final received = <int>[];
      final sub = rec.frames.listen((c) => received.addAll(samples16(c)));
      micCtrl.add(pcm16(List.filled(160, 700)));
      await pump();

      expect(received, List.filled(160, 700)); // the live stream still flows
      expect(rec.pcm, isEmpty); // nothing accumulated
      expect(rec.duration, const Duration(milliseconds: 20)); // still counted
      await sub.cancel();
      await rec.stop();
      await micCtrl.close();
      await board.dispose();
    });

    test(
      'play after dispose is a no-op instead of restarting the bus',
      () async {
        final board = Soundboard(format: _fmt);
        final clip = board.loadBytes(
          pcm16(List.filled(160, 1000)),
          format: _fmt,
        );
        await board.dispose();
        board.play(clip); // must not throw or start a timer
        board.stopAll();
      },
    );

    test('works when registered through the Microphone registry', () async {
      final board = Soundboard(
        format: _fmt,
        chunk: const Duration(milliseconds: 20),
      );
      final micCtrl = StreamController<Uint8List>();
      final mic = StreamCaptureBackend(source: micCtrl.stream, format: _fmt);
      Microphone.registerBackend(
        board.asMicrophoneBackend(physicalMic: mic),
        makeActive: true,
      );
      addTearDown(Microphone.reset);

      final rec = await Microphone.record(format: _fmt);
      board.play(board.loadBytes(pcm16(List.filled(160, 700)), format: _fmt));
      await settle();
      micCtrl.add(pcm16(List.filled(160, 300)));
      await pump();

      expect(samples16(rec.pcm).every((v) => v == 1000), isTrue);
      await rec.stop();
      await micCtrl.close();
      await board.dispose();
    });
  });
}

/// A silent backend whose load() waits for [_gate], like a slow decode.
class _GatedSilentBackend extends SilentBackend {
  _GatedSilentBackend(
    this._gate, {
    this.stopGate,
    super.simulatedDuration = const Duration(seconds: 1),
  });

  final Future<void> _gate;

  /// When set, each playback's stop() and dispose() wait for it.
  final Future<void>? stopGate;
  final List<Playback> playbacks = [];

  @override
  Future<Playback> load(
    SoundSource source, {
    double volume = 1.0,
    bool loop = false,
  }) async {
    await _gate;
    final playback = switch (stopGate) {
      final gate? => _SlowStopPlayback(gate),
      null => await super.load(source, volume: volume, loop: loop),
    };
    playbacks.add(playback);
    return playback;
  }
}

/// A silent backend whose playbacks fail with [_failure], like a native voice
/// error.
class _FailingSilentBackend extends SilentBackend {
  _FailingSilentBackend(this._failure)
    : super(simulatedDuration: const Duration(seconds: 1));

  final Future<void> _failure;

  @override
  Future<Playback> load(
    SoundSource source, {
    double volume = 1.0,
    bool loop = false,
  }) async => _FailingPlayback(_failure);
}

class _FailingPlayback extends SilentPlayback {
  _FailingPlayback(this._failure) : super(const Duration(seconds: 1));

  final Future<void> _failure;

  @override
  Future<void> get onComplete => _failure;
}

class _SlowStopPlayback extends SilentPlayback {
  _SlowStopPlayback(this._stopGate) : super(const Duration(seconds: 1));

  final Future<void> _stopGate;

  @override
  Future<void> stop() async {
    await _stopGate;
    await super.stop();
  }

  @override
  Future<void> dispose() async {
    await _stopGate;
    await super.dispose();
  }
}
