import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/settings_persist.dart';

void main() {
  Widget harness(Future<void> Function() action) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () =>
                persistSetting(context, action, message: 'Save failed'),
            child: const Text('go'),
          ),
        ),
      ),
    );
  }

  testWidgets('shows an error SnackBar when the persist action throws', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(() async {
        throw Exception('boom');
      }),
    );

    await tester.tap(find.text('go'));
    await tester.pump(); // run persistSetting (catch + schedule SnackBar)
    await tester.pump(); // build the SnackBar

    expect(find.text('Save failed'), findsOneWidget);
  });

  testWidgets('shows no SnackBar when the persist action succeeds', (
    tester,
  ) async {
    await tester.pumpWidget(harness(() async {}));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
  });
}
