import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:microphone_flutter/microphone_flutter.dart';

void main() {
  runApp(const MicrophoneApp());
}

class MicrophoneApp extends StatelessWidget {
  const MicrophoneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'microphone_dart',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const RecorderPage(),
    );
  }
}

class RecorderPage extends StatefulWidget {
  const RecorderPage({super.key});

  @override
  State<RecorderPage> createState() => _RecorderPageState();
}

class _RecorderPageState extends State<RecorderPage> {
  String _backend = '...';
  String _status = 'idle';
  Recording? _recording;
  StreamSubscription<AudioLevel>? _levels;
  double _level = 0; // 0..1 live RMS level
  Uint8List? _lastWav;
  List<CaptureDevice> _devices = const [];
  String? _deviceId; // null = system default

  @override
  void initState() {
    super.initState();
    MicrophoneFlutter.ensureInitialized().then((name) async {
      debugPrint('microphone_dart backend: $name');
      if (mounted) setState(() => _backend = name);
      await _loadDevices();
      // Headless self-test: when MIC_SELFTEST is set, record ~1s and log the
      // captured byte count, so emulator/simulator runs can be checked from
      // logs without driving the UI.
      if (const bool.fromEnvironment('MIC_SELFTEST') ||
          const String.fromEnvironment('MIC_SELFTEST').isNotEmpty) {
        _selfTest();
      }
    });
  }

  @override
  void dispose() {
    _levels?.cancel();
    _recording?.dispose();
    super.dispose();
  }

  /// Records ~1s and logs the result. Used for non-interactive verification on
  /// simulators/emulators via `--dart-define=MIC_SELFTEST=1`.
  Future<void> _selfTest() async {
    try {
      await Microphone.requestPermission();
      final recording = await Microphone.record();
      debugPrint('mic selftest: recording on ${recording.format}');
      await Future<void>.delayed(const Duration(seconds: 1));
      final wav = await recording.stop();
      await recording.dispose();
      debugPrint(
        'mic selftest: captured ${wav.length} bytes, '
        '${recording.duration.inMilliseconds} ms',
      );
    } on Object catch (e) {
      debugPrint('mic selftest failed: $e');
    }
  }

  /// Loads the input device list (labels may need permission on the web).
  Future<void> _loadDevices() async {
    try {
      final devices = await Microphone.devices();
      if (mounted) setState(() => _devices = devices);
    } on Object {
      // Enumeration is best-effort; the default device still works.
    }
  }

  Future<void> _start() async {
    if (!await Microphone.requestPermission()) {
      setState(() => _status = 'permission denied');
      return;
    }
    // Web labels appear only after permission; refresh once granted.
    if (_devices.every((d) => d.label.isEmpty || d.label == 'Microphone')) {
      await _loadDevices();
    }
    try {
      final recording = await Microphone.record(deviceId: _deviceId);
      _levels = recording.levels().listen((level) {
        if (mounted) setState(() => _level = level.rms);
      });
      setState(() {
        _recording = recording;
        _lastWav = null;
        _status = 'recording at ${recording.format.sampleRate} Hz';
      });
    } on Object catch (e) {
      setState(() => _status = 'error: $e');
    }
  }

  Future<void> _togglePause() async {
    final recording = _recording;
    if (recording == null) return;
    if (recording.state == RecordingState.paused) {
      await recording.resume();
    } else {
      await recording.pause();
    }
    setState(() => _status = recording.state.name);
  }

  Future<void> _stop() async {
    final recording = _recording;
    if (recording == null) return;
    await _levels?.cancel();
    _levels = null;
    final wav = await recording.stop();
    await recording.dispose();
    setState(() {
      _recording = null;
      _level = 0;
      _lastWav = wav;
      _status =
          'recorded ${recording.duration.inMilliseconds} ms, ${wav.length} bytes';
    });
  }

  @override
  Widget build(BuildContext context) {
    final recording = _recording != null;
    final paused = _recording?.state == RecordingState.paused;
    return Scaffold(
      appBar: AppBar(title: const Text('microphone_dart')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Backend: $_backend'),
            const SizedBox(height: 8),
            Text('Status: $_status'),
            const SizedBox(height: 16),
            // Input device picker (when enumeration is available).
            if (_devices.isNotEmpty)
              DropdownButton<String?>(
                isExpanded: true,
                value: _deviceId,
                hint: const Text('System default'),
                onChanged: recording
                    ? null
                    : (id) => setState(() => _deviceId = id),
                items: [
                  const DropdownMenuItem<String?>(
                    child: Text('System default'),
                  ),
                  for (final d in _devices)
                    DropdownMenuItem<String?>(
                      value: d.id,
                      child: Text(
                        d.isDefault ? '${d.label} (default)' : d.label,
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 24),
            // Live input level.
            LinearProgressIndicator(value: _level, minHeight: 12),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                FilledButton.icon(
                  onPressed: recording ? null : _start,
                  icon: const Icon(Icons.mic),
                  label: const Text('Record'),
                ),
                FilledButton.icon(
                  onPressed: recording ? _togglePause : null,
                  icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                  label: Text(paused ? 'Resume' : 'Pause'),
                ),
                FilledButton.icon(
                  onPressed: recording ? _stop : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (_lastWav != null)
              Text(
                'Last recording: ${_lastWav!.length} bytes of WAV in memory.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}
