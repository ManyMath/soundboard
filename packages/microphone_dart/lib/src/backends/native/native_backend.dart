import '../../capture_backend.dart';

// Selects the FFI implementation on native platforms and the web capture
// backend on the web, so importing `microphone_dart` never pulls in
// `dart:ffi` where it does not exist.
import 'native_backend_ffi.dart'
    if (dart.library.js_interop) 'native_backend_web.dart'
    as impl;

/// Returns the default capture backend for this platform, or `null` when none
/// applies and only the silent fallback should be used.
CaptureBackend? createNativeBackend() => impl.createNativeBackend();
