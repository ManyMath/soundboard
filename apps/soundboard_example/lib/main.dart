import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:microphone_flutter/microphone_flutter.dart';
import 'package:sound_flutter/sound_flutter.dart';
import 'package:soundboard/soundboard.dart';

import 'virtual_mic.dart';

// The soundboard mix format. Stereo 48 kHz matches BlackHole 2ch; PipeWire
// resamples as needed.
const _fmt = CaptureFormat(sampleRate: 48000, channels: 2);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Eagerly load the native libraries so the first record/play has no latency
  // and load errors surface at startup.
  await SoundFlutter.ensureInitialized();
  await MicrophoneFlutter.ensureInitialized();
  runApp(const SoundboardApp());
}

class SoundboardApp extends StatelessWidget {
  const SoundboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soundboard',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  VirtualMicSupport? _support;
  List<CaptureDevice> _inputs = const [];
  String? _selectedDeviceId; // null = system default

  Soundboard? _board;
  VirtualMic? _vmic;
  Recording? _recording;
  bool _live = false;
  bool _busy = false;
  String? _error;

  double _masterVolume = 1.0;
  double _micVolume = 1.0;

  // Loaded test tones.
  Clip? _beep;
  Clip? _chord;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final support = await VirtualMicPlatform.support();
    List<CaptureDevice> inputs = const [];
    try {
      inputs = await Microphone.devices();
    } on Object {
      // Enumeration may fail before permission is granted; the dropdown then
      // just offers the system default.
    }
    if (!mounted) return;
    setState(() {
      _support = support;
      _inputs = inputs;
    });
  }

  Future<void> _start() async {
    if (_busy || _live) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // Each resource is assigned to its state field the moment it exists, so
    // the catch below can always tear down whatever was created before the
    // failure (otherwise an error after startRecording would leave the
    // microphone capturing with no handle to stop it).
    try {
      // Microphone capture needs permission; ask before wiring the mix.
      if (!await Microphone.requestPermission()) {
        if (mounted) {
          setState(() => _error = 'Microphone permission was denied.');
        }
        return;
      }

      final board = _board = Soundboard(format: _fmt)
        ..masterVolume = _masterVolume
        ..micVolume = _micVolume;
      _beep = board.loadBytes(
        _sine(660, const Duration(milliseconds: 300), _fmt),
        format: _fmt,
      );
      _chord = board.loadBytes(_chordTone(_fmt), format: _fmt);

      // retainPcm: false -- a live session is open-ended, so the recording
      // must not accumulate the whole session's PCM in memory. deviceId binds
      // the chosen input (null = system default).
      final recording = _recording = await board
          .asMicrophoneBackend()
          .startRecording(
            format: _fmt,
            deviceId: _selectedDeviceId,
            retainPcm: false,
          );

      final vmic = _vmic = await VirtualMicPlatform.create(format: _fmt);
      unawaited(
        vmic.feed(recording.frames).catchError((Object e) {
          if (mounted) setState(() => _error = 'Feeding stopped: $e');
        }),
      );

      // Refresh the device list now that permission likely granted names.
      final inputs = await Microphone.devices();

      if (!mounted) {
        await _teardown();
        return;
      }
      setState(() {
        _inputs = inputs;
        _live = true;
      });
    } on Object catch (e) {
      await _teardown();
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _teardown();
    if (mounted) {
      setState(() {
        _live = false;
        _busy = false;
      });
    }
  }

  bool _tearingDown = false;

  Future<void> _teardown() async {
    if (_tearingDown) return;
    _tearingDown = true;
    try {
      await _recording?.stop().catchError((Object _) => Uint8List(0));
      await _vmic?.dispose();
      await _board?.dispose();
      _recording = null;
      _vmic = null;
      _board = null;
    } finally {
      _tearingDown = false;
    }
  }

  @override
  void dispose() {
    unawaited(_teardown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final support = _support;
    return Scaffold(
      appBar: AppBar(title: const Text('Soundboard virtual microphone')),
      body: support == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _statusCard(support),
                  const SizedBox(height: 16),
                  _deviceCard(support),
                  const SizedBox(height: 16),
                  _tonesCard(),
                  const SizedBox(height: 16),
                  _mixerCard(),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    _errorCard(_error!),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _statusCard(VirtualMicSupport support) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  support.supported ? Icons.check_circle : Icons.error_outline,
                  color: support.supported ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    support.supported
                        ? 'Virtual microphone available'
                        : 'Virtual microphone unavailable',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Platform: ${support.platformLabel}'),
            if (_live && _vmic != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Live device: "${_vmic!.deviceName}"  '
                  '(${_vmic!.format.sampleRate} Hz, '
                  '${_vmic!.format.channels} ch)\n'
                  'Select it as your microphone in any app.',
                ),
              ),
            if (!support.supported)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  support.hint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy || !support.supported
                  ? null
                  : (_live ? _stop : _start),
              icon: Icon(_live ? Icons.stop : Icons.podcasts),
              label: Text(_live ? 'Stop virtual microphone' : 'Go live'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceCard(VirtualMicSupport support) {
    final items = <DropdownMenuItem<String?>>[
      const DropdownMenuItem(value: null, child: Text('System default input')),
      for (final d in _inputs)
        DropdownMenuItem(
          value: d.id,
          child: Text(d.isDefault ? '${d.label} (default)' : d.label),
        ),
    ];
    // Keep the selection valid if the device list changed under us.
    final value = items.any((i) => i.value == _selectedDeviceId)
        ? _selectedDeviceId
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Microphone to mix in',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            DropdownButton<String?>(
              isExpanded: true,
              value: value,
              items: items,
              // The device is bound when going live, so lock it while live.
              onChanged: _live
                  ? null
                  : (v) => setState(() => _selectedDeviceId = v),
            ),
            const SizedBox(height: 4),
            Text(
              _inputs.isEmpty
                  ? 'No named inputs yet. Grant microphone permission (Go live) '
                        'to enumerate devices; the system default is used until '
                        'then.'
                  : '${_inputs.length} input device(s) detected.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _tonesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Test sounds', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              _live
                  ? 'These mix into the virtual microphone.'
                  : 'Go live first; tones mix into the virtual microphone.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _live ? () => _board?.play(_beep!) : null,
                  icon: const Icon(Icons.notifications_active),
                  label: const Text('Beep (660 Hz)'),
                ),
                ElevatedButton.icon(
                  onPressed: _live ? () => _board?.play(_chord!) : null,
                  icon: const Icon(Icons.music_note),
                  label: const Text('Chord'),
                ),
                OutlinedButton.icon(
                  onPressed: _live ? () => _board?.stopAll() : null,
                  icon: const Icon(Icons.stop_circle),
                  label: const Text('Stop tones'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _mixerCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mix', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _slider(
              'Clip volume',
              _masterVolume,
              (v) => setState(() {
                _masterVolume = v;
                _board?.masterVolume = v;
              }),
            ),
            _slider(
              'Microphone volume',
              _micVolume,
              (v) => setState(() {
                _micVolume = v;
                _board?.micVolume = v;
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider(String label, double value, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 140, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            max: 2.0,
            divisions: 20,
            label: value.toStringAsFixed(2),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _errorCard(String message) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
        ),
      ),
    );
  }
}

// --- test tones ------------------------------------------------------------

Uint8List _sine(double freq, Duration dur, CaptureFormat fmt) {
  final frames = fmt.sampleRate * dur.inMilliseconds ~/ 1000;
  final out = Uint8List(frames * fmt.channels * 2);
  final view = ByteData.sublistView(out);
  var o = 0;
  for (var i = 0; i < frames; i++) {
    final v = (0.3 * sin(2 * pi * freq * i / fmt.sampleRate) * 32767).round();
    for (var c = 0; c < fmt.channels; c++) {
      view.setInt16(o, v, Endian.little);
      o += 2;
    }
  }
  return out;
}

/// A short major triad (C5-E5-G5) so the "chord" button is audibly different
/// from the beep.
Uint8List _chordTone(CaptureFormat fmt) {
  const dur = Duration(milliseconds: 600);
  const freqs = [523.25, 659.25, 783.99];
  final frames = fmt.sampleRate * dur.inMilliseconds ~/ 1000;
  final out = Uint8List(frames * fmt.channels * 2);
  final view = ByteData.sublistView(out);
  var o = 0;
  for (var i = 0; i < frames; i++) {
    var s = 0.0;
    for (final f in freqs) {
      s += sin(2 * pi * f * i / fmt.sampleRate);
    }
    // Gentle fade-out to avoid an end click.
    final fade = 1.0 - (i / frames);
    final v = (0.18 * s * fade * 32767).round().clamp(-32768, 32767);
    for (var c = 0; c < fmt.channels; c++) {
      view.setInt16(o, v, Endian.little);
      o += 2;
    }
  }
  return out;
}
