import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/widgets/storage_unavailable_banner.dart';

/// #385: the banner must be invisible when healthy and a loud, persistent
/// warning above the app when storage is down.
Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('hidden when show=false: only the child renders', (tester) async {
    await tester.pumpWidget(
      _wrap(const StorageUnavailableBanner(show: false, child: Text('APP'))),
    );

    expect(find.text('APP'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.textContaining('NOT being saved'), findsNothing);
  });

  testWidgets('shown when show=true: warning + restart hint above the child', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const StorageUnavailableBanner(show: true, child: Text('APP'))),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.textContaining('NOT being saved'), findsOneWidget);
    expect(find.textContaining('Restart the app'), findsOneWidget);
    // The app content is still present below the banner.
    expect(find.text('APP'), findsOneWidget);
  });
}
