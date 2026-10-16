import 'package:flutter/services.dart';
import 'package:microphone_dart/microphone_dart.dart';
import 'package:microphone_dart/platform_hooks.dart';

/// Registered automatically on Android (the plugin's `dartPluginClass`): routes
/// what the native backend cannot do there -- the permission check and request
/// (asking for `RECORD_AUDIO` needs the app's Activity) and listing inputs
/// (AAudio cannot) -- through the plugin's Java side.
abstract final class MicrophoneFlutterAndroid {
  static const _channel = MethodChannel('microphone_flutter');

  static void registerWith() {
    NativePlatform.checkPermission = () async =>
        await _channel.invokeMethod<bool>('hasPermission') ?? false;
    NativePlatform.requestPermission = () async =>
        await _channel.invokeMethod<bool>('requestPermission') ?? false;
    NativePlatform.devices = _devices;
  }

  static Future<List<CaptureDevice>> _devices() async {
    final inputs =
        await _channel.invokeListMethod<Map<Object?, Object?>>('devices') ??
        const [];
    return [
      // The route Android picks when no device is pinned.
      const CaptureDevice(id: 'default', label: 'Default', isDefault: true),
      for (final input in inputs)
        CaptureDevice(
          id: '${input['id']}',
          label: input['name'] as String? ?? 'Input ${input['id']}',
        ),
    ];
  }
}
