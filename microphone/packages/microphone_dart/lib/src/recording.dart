import 'dart:typed_data';

import 'capture_format.dart';

/// Lifecycle states of a [Recording].
enum RecordingState {
  /// Created but not yet started.
  idle,

  /// Actively capturing audio.
  recording,

  /// Paused; capture is suspended and can be resumed.
  paused,

  /// Stopped; the captured audio is final and the handle holds it.
  stopped,

  /// Resources released; the handle can no longer be used.
  disposed,
}

/// A handle to a single in-progress or finished recording.
///
/// Backends return their own implementation from
/// [CaptureBackend.startRecording]. While recording, captured PCM is delivered
/// two ways at once: live, frame by frame, over [frames]; and accumulated, so
/// [stop] can return the whole clip as WAV bytes. Apps that only want a file
/// can ignore [frames]; apps that only want to monitor levels can ignore the
/// return of [stop].
abstract class Recording {
  /// The current lifecycle state.
  RecordingState get state;

  /// Whether audio is currently being captured.
  bool get isRecording => state == RecordingState.recording;

  /// The audio format actually in effect, which may differ from the one
  /// requested if the device forced its own (e.g. a fixed sample rate).
  CaptureFormat get format;

  /// A live stream of captured PCM frames in [format].
  ///
  /// Each event is a chunk of interleaved samples (not necessarily a fixed
  /// size). The stream closes when the recording stops or is disposed. It is a
  /// broadcast stream, so listening late is allowed but misses earlier frames;
  /// use the bytes from [stop] for the complete capture.
  Stream<Uint8List> get frames;

  /// The total audio captured so far, in time. Excludes paused gaps.
  Duration get duration;

  /// Pauses capture, keeping what was already captured.
  ///
  /// Audio arriving while paused is dropped, so the recording has no silent gap
  /// for the paused interval -- [resume] continues right where [pause] left off.
  /// Safe to call when not recording.
  Future<void> pause();

  /// Resumes a paused capture. Safe to call when not paused.
  Future<void> resume();

  /// Stops capture and returns the full recording as WAV (RIFF) bytes.
  ///
  /// Safe to call more than once; later calls return the same bytes. After this
  /// the [frames] stream is closed.
  Future<Uint8List> stop();

  /// Stops (if needed) and writes the recording to [path] as a WAV file.
  ///
  /// Returns [path]. Not supported on the web, where there is no file system;
  /// call [stop] and handle the bytes yourself there.
  Future<String> stopToFile(String path);

  /// The accumulated raw PCM captured so far, without a WAV header.
  Uint8List get pcm;

  /// Releases resources. If still recording, capture stops first. The handle is
  /// unusable afterward.
  Future<void> dispose();
}
