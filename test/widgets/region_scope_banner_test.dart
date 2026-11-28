// Region-scope banner on the channel chat (#1258).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/widgets/region_scope_banner.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required String? regionName,
    VoidCallback? onTap,
    VoidCallback? onDismiss,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RegionScopeBanner(
            regionName: regionName,
            onTap: onTap ?? () {},
            onDismiss: onDismiss ?? () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the scoped region name', (tester) async {
    await pump(tester, regionName: 'cvg');
    expect(find.textContaining('cvg'), findsOneWidget);
  });

  testWidgets('tapping the banner opens Set Region Scope (onTap)', (
    tester,
  ) async {
    var taps = 0;
    await pump(tester, regionName: 'cvg', onTap: () => taps++);
    await tester.tap(find.byKey(const Key('regionScopeBannerBody')));
    expect(taps, 1);
  });

  testWidgets('tapping dismiss fires onDismiss', (tester) async {
    var dismissed = 0;
    await pump(tester, regionName: 'cvg', onDismiss: () => dismissed++);
    await tester.tap(find.byKey(const Key('regionScopeBannerDismiss')));
    expect(dismissed, 1);
  });

  testWidgets('renders nothing when the channel is not scoped', (tester) async {
    await pump(tester, regionName: null);
    expect(find.byKey(const Key('regionScopeBannerBody')), findsNothing);
  });
}
