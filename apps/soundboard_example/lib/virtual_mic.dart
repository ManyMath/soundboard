// Desktop adapters are unavailable in a browser.
export 'virtual_mic_unsupported.dart'
    if (dart.library.io) 'virtual_mic_native.dart';
