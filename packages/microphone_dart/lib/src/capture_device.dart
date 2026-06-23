/// An input device the microphone can capture from.
///
/// [id] is an opaque, backend-specific handle to pass to
/// `Microphone.record(deviceId: ...)`; it is stable within a session but not
/// guaranteed across reboots or device re-plugs. [label] is a human-readable
/// name for display.
class CaptureDevice {
  const CaptureDevice({
    required this.id,
    required this.label,
    this.isDefault = false,
  });

  /// Opaque backend-specific device handle.
  final String id;

  /// Human-readable device name (e.g. "MacBook Pro Microphone").
  final String label;

  /// Whether this is the system default input.
  final bool isDefault;

  @override
  bool operator ==(Object other) =>
      other is CaptureDevice &&
      other.id == id &&
      other.label == label &&
      other.isDefault == isDefault;

  @override
  int get hashCode => Object.hash(id, label, isDefault);

  @override
  String toString() =>
      'CaptureDevice($label${isDefault ? ', default' : ''}, id: $id)';
}
