// Widget smoke test: the app builds and shows its main controls. It does not
// drive the native virtual-mic path (that needs a device and is verified by
// running the app); it just confirms the UI renders past the initial load.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soundboard_example/main.dart';

void main() {
  testWidgets('app renders the virtual-microphone controls', (tester) async {
    await tester.pumpWidget(const SoundboardApp());
    // The support probe runs in initState; let it settle.
    await tester.pumpAndSettle();

    expect(find.text('Soundboard virtual microphone'), findsOneWidget);
    expect(find.text('Test sounds'), findsOneWidget);
    expect(find.text('Microphone to mix in'), findsOneWidget);
    expect(find.text('Beep (660 Hz)'), findsOneWidget);
    expect(find.text('Chord'), findsOneWidget);
  });
}
