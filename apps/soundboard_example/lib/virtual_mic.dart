// A tiny platform-neutral facade over the soundboard's OS-level virtual
// microphones: CoreAudio (BlackHole) on macOS, PipeWire on Linux. The UI talks
// to this and never touches the platform-specific classes directly.
//
// Both backends expose the same shape -- isSupported / create / feed / dispose
// plus a display name -- so the facade just forwards to whichever platform is
// running. Importing both entry points here is fine: both are dart:io based and
// this file is only used on desktop.

import 'dart:io';
import 'dart:typed_data';

import 'package:soundboard/coreaudio.dart';
import 'package:soundboard/pipewire.dart';
import 'package:soundboard/soundboard.dart';

/// What the running platform's virtual-microphone support looks like, for the
/// UI to explain itself when unsupported.
class VirtualMicSupport {
  const VirtualMicSupport({
    required this.supported,
    required this.platformLabel,
    required this.hint,
  });

  final bool supported;
  final String platformLabel;

  /// A one-line install/setup hint shown when [supported] is false.
  final String hint;
}

/// A live virtual microphone the app is feeding. Wraps the platform object.
class VirtualMic {
  VirtualMic._(this._dispose, this._feed, this.deviceName, this.format);

  final Future<void> Function() _dispose;
  final Future<void> Function(Stream<Uint8List>) _feed;

  /// The device name apps see in their input menu.
  final String deviceName;

  /// The format streamed into the device.
  final CaptureFormat format;

  Future<void> feed(Stream<Uint8List> pcm) => _feed(pcm);
  Future<void> dispose() => _dispose();
}

/// Platform facade. Static-only.
abstract final class VirtualMicPlatform {
  /// Whether the current desktop platform can host a virtual microphone, with a
  /// label and a setup hint for the UI. Never throws.
  static Future<VirtualMicSupport> support() async {
    if (Platform.isMacOS) {
      return VirtualMicSupport(
        supported: await CoreAudioVirtualMic.isSupported(),
        platformLabel: 'macOS (CoreAudio / BlackHole)',
        hint:
            'Install a loopback device with "brew install blackhole-2ch", then '
            'reload audio with "sudo killall coreaudiod" (or reboot).',
      );
    }
    if (Platform.isLinux) {
      return VirtualMicSupport(
        supported: await PipeWireVirtualMic.isSupported(),
        platformLabel: 'Linux (PipeWire)',
        hint:
            'Needs a running PipeWire session with the pw-loopback and pw-cat '
            'tools (install the "pipewire" package).',
      );
    }
    return const VirtualMicSupport(
      supported: false,
      platformLabel: 'unsupported platform',
      hint: 'A virtual microphone device is only available on macOS and Linux.',
    );
  }

  /// Creates the platform virtual microphone at [format]. Throws the platform's
  /// own exception (CoreAudioException / PipeWireException) when it cannot.
  static Future<VirtualMic> create({required CaptureFormat format}) async {
    if (Platform.isMacOS) {
      final mic = await CoreAudioVirtualMic.create(format: format);
      return VirtualMic._(mic.dispose, mic.feed, mic.deviceName, mic.format);
    }
    if (Platform.isLinux) {
      final mic = await PipeWireVirtualMic.create(
        name: 'Soundboard',
        format: format,
      );
      return VirtualMic._(mic.dispose, mic.feed, mic.name, mic.format);
    }
    throw StateError('virtual microphone is not supported on this platform');
  }
}
