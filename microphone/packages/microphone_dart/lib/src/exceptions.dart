/// Base class for all errors thrown by `microphone_dart`.
class MicrophoneException implements Exception {
  const MicrophoneException(this.message);

  final String message;

  @override
  String toString() => 'MicrophoneException: $message';
}

/// Thrown when no registered backend can run in the current environment.
class NoBackendAvailableException extends MicrophoneException {
  const NoBackendAvailableException([
    super.message =
        'No microphone backend is available in this environment. '
        'Register one with Microphone.registerBackend, or use '
        'microphone_flutter.',
  ]);
}

/// Thrown when microphone access is denied (no permission, or the user declined
/// the OS prompt).
class PermissionDeniedException extends MicrophoneException {
  const PermissionDeniedException([
    super.message = 'Microphone permission was denied.',
  ]);
}

/// Thrown when the native capture layer reports a failure.
class CaptureException extends MicrophoneException {
  const CaptureException(super.message);
}
