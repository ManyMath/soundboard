@TestOn('vm')
library;

import 'package:soundboard/pipewire.dart';
import 'package:soundboard/soundboard.dart';
import 'package:test/test.dart';

void main() {
  group('PipeWireCommands.sanitizeNodeName', () {
    test('lowercases and replaces disallowed characters', () {
      expect(PipeWireCommands.sanitizeNodeName('Soundboard'), 'soundboard');
      expect(PipeWireCommands.sanitizeNodeName('My Mic!'), 'my_mic_');
      expect(PipeWireCommands.sanitizeNodeName('a.b-c_d'), 'a.b-c_d');
    });

    test('falls back to a default for an empty result', () {
      expect(PipeWireCommands.sanitizeNodeName(''), 'soundboard');
      expect(PipeWireCommands.sanitizeNodeName('***'), '___');
    });
  });

  group('PipeWireCommands.loopbackArgs', () {
    test('publishes a sink bridged to a source with the channel count', () {
      final args = PipeWireCommands.loopbackArgs(
        sinkName: 'soundboard_sink',
        sourceName: 'soundboard',
        description: 'Soundboard',
        channels: 2,
      );
      expect(args, [
        '--channels=2',
        '--capture-props=media.class=Audio/Sink node.name=soundboard_sink',
        '--playback-props=media.class=Audio/Source node.name=soundboard '
            'node.description="Soundboard"',
      ]);
    });

    test('quotes a description that contains spaces', () {
      final args = PipeWireCommands.loopbackArgs(
        sinkName: 's',
        sourceName: 'm',
        description: 'My Soundboard',
        channels: 1,
      );
      expect(args.last, contains('node.description="My Soundboard"'));
    });
  });

  group('PipeWireCommands.feedArgs', () {
    test('streams raw S16 from stdin into the target sink', () {
      expect(
        PipeWireCommands.feedArgs(
          sinkName: 'soundboard_sink',
          sampleRate: 48000,
          channels: 1,
        ),
        [
          '-p',
          '--target=soundboard_sink',
          '-P',
          '{ node.dont-reconnect = true }',
          '--format=s16',
          '--rate=48000',
          '--channels=1',
          '-',
        ],
      );
    });
  });

  group('PipeWireVirtualMic.isSupported', () {
    test('returns a bool without throwing, regardless of platform', () async {
      expect(await PipeWireVirtualMic.isSupported(), isA<bool>());
    });
  });

  group('PipeWireVirtualMic.create', () {
    test('throws PipeWireUnavailableException when unsupported', () async {
      // Only assert the typed failure when this host cannot host one (e.g. CI).
      // On a live PipeWire desktop create() would succeed, so skip there.
      if (await PipeWireVirtualMic.isSupported()) return;
      expect(
        () => PipeWireVirtualMic.create(
          name: 'Soundboard',
          format: const CaptureFormat(),
        ),
        throwsA(isA<PipeWireUnavailableException>()),
      );
    });
  });
}
