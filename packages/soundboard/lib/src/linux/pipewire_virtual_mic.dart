import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:microphone_dart/microphone_dart.dart' show CaptureFormat;

/// Thrown when a PipeWire virtual microphone cannot be created or operated.
class PipeWireException implements Exception {
  const PipeWireException(this.message);
  final String message;
  @override
  String toString() => 'PipeWireException: $message';
}

/// Thrown by [PipeWireVirtualMic.create] when the environment cannot host one
/// (not Linux, PipeWire not running, or `pw-loopback`/`pw-cat` not installed).
class PipeWireUnavailableException extends PipeWireException {
  const PipeWireUnavailableException([
    super.message =
        'PipeWire virtual microphone is unavailable: needs Linux with a '
        'running PipeWire session and the pw-loopback and pw-cat tools '
        '(install the pipewire package).',
  ]);
}

/// Pure builders for the PipeWire command lines, separated so they can be unit
/// tested without a running PipeWire session.
class PipeWireCommands {
  PipeWireCommands._();

  /// A valid PipeWire `node.name` derived from a human name (lowercase, with
  /// anything outside `[a-z0-9_.-]` replaced by `_`).
  static String sanitizeNodeName(String name) {
    final s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_.-]'), '_');
    return s.isEmpty ? 'soundboard' : s;
  }

  /// Quotes a property value for a PipeWire props string, dropping characters
  /// that would break the parser.
  static String quoteProp(String value) =>
      '"${value.replaceAll('"', '').replaceAll('\n', ' ')}"';

  /// `pw-loopback` arguments that publish an `Audio/Sink` (fed by us) bridged to
  /// an `Audio/Source` (the virtual microphone apps select).
  static List<String> loopbackArgs({
    required String sinkName,
    required String sourceName,
    required String description,
    required int channels,
  }) => [
    '--channels=$channels',
    '--capture-props=media.class=Audio/Sink node.name=$sinkName',
    '--playback-props=media.class=Audio/Source node.name=$sourceName '
        'node.description=${quoteProp(description)}',
  ];

  /// `pw-cat` arguments that stream raw interleaved S16LE PCM from stdin into
  /// the bridge sink.
  static List<String> feedArgs({
    required String sinkName,
    required int sampleRate,
    required int channels,
  }) => [
    '-p',
    '--target=$sinkName',
    '--format=s16',
    '--rate=$sampleRate',
    '--channels=$channels',
    '-',
  ];
}

/// A Linux virtual microphone, backed by PipeWire, that other applications
/// (a call, a stream, a browser) can select as their input.
///
/// It runs two child processes: a `pw-loopback` bridge that publishes the
/// device, and a `pw-cat` feeder that streams PCM into it. The device exists
/// only while they run, so [dispose] (which kills them) removes it cleanly --
/// there is no module to leak.
///
/// ```dart
/// final vmic = await PipeWireVirtualMic.create(name: 'Soundboard', format: f);
/// final recording = await board.asMicrophoneBackend().startRecording(format: f);
/// unawaited(vmic.feed(recording.frames));
/// // ... the app now hears the soundboard on the "Soundboard" mic ...
/// await vmic.dispose();
/// ```
class PipeWireVirtualMic {
  PipeWireVirtualMic._(
    this._loopback,
    this.sinkNodeName,
    this.sourceNodeName,
    this.name,
    this.format,
  ) {
    _loopback.exitCode.then((_) => _loopbackExited = true);
  }

  /// The human-readable name apps show in their input menu.
  final String name;

  /// The format streamed into the device.
  final CaptureFormat format;

  /// The PipeWire `node.name` of the virtual source (the microphone).
  final String sourceNodeName;

  /// The PipeWire `node.name` of the bridge sink that is fed.
  final String sinkNodeName;

  final Process _loopback;
  bool _loopbackExited = false;
  Process? _feeder;
  Future<void>? _feedDone;
  bool _disposed = false;

  /// Whether this environment can host a PipeWire virtual microphone: Linux,
  /// with `pw-loopback`/`pw-cat`/`pw-cli` installed and a running PipeWire
  /// session. Never throws.
  static Future<bool> isSupported() async {
    if (!Platform.isLinux) return false;
    // pw-cli is needed too: create() uses it to confirm the node registered.
    for (final tool in const ['pw-loopback', 'pw-cat', 'pw-cli']) {
      if (!await _hasTool(tool)) return false;
    }
    return _pipewireRunning();
  }

  /// Creates and registers the virtual microphone.
  ///
  /// [name] is the label apps show; [format] is the PCM format streamed into it
  /// (PipeWire resamples to the graph rate as needed). Throws
  /// [PipeWireUnavailableException] if [isSupported] is false, and
  /// [PipeWireException] if the device does not appear.
  static Future<PipeWireVirtualMic> create({
    String name = 'Soundboard',
    CaptureFormat format = const CaptureFormat(),
  }) async {
    if (!await isSupported()) throw const PipeWireUnavailableException();
    final source = PipeWireCommands.sanitizeNodeName(name);
    final sink = '${source}_sink';
    final Process loopback;
    try {
      loopback = await Process.start(
        'pw-loopback',
        PipeWireCommands.loopbackArgs(
          sinkName: sink,
          sourceName: source,
          description: name,
          channels: format.channels,
        ),
      );
    } on Object catch (e) {
      throw PipeWireException('failed to start pw-loopback: $e');
    }
    final mic = PipeWireVirtualMic._(loopback, sink, source, name, format);
    if (!await mic._waitForNode(source, const Duration(seconds: 5))) {
      await mic.dispose();
      throw const PipeWireException(
        'the virtual microphone did not register (pw-loopback failed).',
      );
    }
    return mic;
  }

  /// Streams [pcm] (interleaved S16LE frames at [format]) into the device.
  /// Call once.
  ///
  /// The returned future completes when [pcm] closes or [dispose] is called,
  /// and completes with a [PipeWireException] if feeding fails while the mic
  /// is still live (e.g. pw-cat died). Callers that keep running while feeding
  /// should not `await` it inline:
  ///
  /// ```dart
  /// unawaited(vmic.feed(recording.frames));
  /// ```
  Future<void> feed(Stream<Uint8List> pcm) async {
    if (_disposed) throw const PipeWireException('virtual mic disposed');
    if (_feeder != null) throw StateError('feed() already called');
    final Process feeder;
    try {
      feeder = await Process.start(
        'pw-cat',
        PipeWireCommands.feedArgs(
          sinkName: sinkNodeName,
          sampleRate: format.sampleRate,
          channels: format.channels,
        ),
      );
    } on Object catch (e) {
      throw PipeWireException('failed to start pw-cat: $e');
    }
    _feeder = feeder;
    // Writing to a killed feeder raises a broken-pipe error on dispose; that
    // is the normal way feeding ends, so it only surfaces as an error when the
    // mic is still supposed to be live.
    final done = feeder.stdin
        .addStream(pcm)
        .then((_) => feeder.stdin.close())
        .then<void>(
          (_) {},
          onError: (Object e) {
            if (!_disposed) {
              throw PipeWireException(
                'feeding the virtual microphone failed: $e',
              );
            }
          },
        );
    // dispose() awaits the swallowed variant so it never rethrows there.
    _feedDone = done.catchError((Object _) {});
    return done;
  }

  /// Removes the virtual microphone by stopping its processes. Idempotent.
  /// Completes a pending [feed] future.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _feeder?.kill();
    _loopback.kill();
    await _feedDone;
    await _safeExit(_feeder);
    await _safeExit(_loopback);
  }

  Future<bool> _waitForNode(String node, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_loopbackExited) return false;
      try {
        final r = await Process.run('pw-cli', ['ls', 'Node']);
        if (r.exitCode == 0 &&
            (r.stdout as String).contains('node.name = "$node"')) {
          return true;
        }
      } on Object {
        // pw-cli hiccup; retry until the deadline.
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return false;
  }

  static Future<bool> _hasTool(String tool) async {
    try {
      final r = await Process.run('which', [tool]);
      return r.exitCode == 0;
    } on Object {
      return false;
    }
  }

  static Future<bool> _pipewireRunning() async {
    final runtime = Platform.environment['XDG_RUNTIME_DIR'];
    if (runtime != null && File('$runtime/pipewire-0').existsSync()) {
      return true;
    }
    try {
      final r = await Process.run('pw-cli', [
        'info',
        '0',
      ]).timeout(const Duration(seconds: 2));
      return r.exitCode == 0;
    } on Object {
      return false;
    }
  }

  static Future<void> _safeExit(Process? p) async {
    if (p == null) return;
    try {
      await p.exitCode.timeout(const Duration(seconds: 2));
    } on Object {
      // Already gone or slow to reap; nothing more we can do safely.
    }
  }
}
