/// Windows-only virtual-microphone support through an installed virtual cable.
///
/// The first implementation targets VB-CABLE: Soundboard writes to its
/// `CABLE Input` playback endpoint and voice applications select the paired
/// `CABLE Output` recording endpoint. This keeps driver installation and
/// signing outside the Dart package while preserving a stable API for a later
/// ManyMath driver.
library;

export 'src/windows/windows_virtual_mic.dart';
