import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/services/ui_view_state_service.dart';
import 'package:meshcore_open/widgets/app_shell.dart';
import 'package:provider/provider.dart';

/// #389: Back must pop out of a pushed detail (a channel chat) to its list, and
/// background the app only from a genuine top-level tab, not the other way
/// round. These pin the full decision matrix.
void main() {
  group('AppShell.backAction', () {
    test('an open drawer closes first, regardless of anything else', () {
      expect(
        AppShell.backAction(drawerOpen: true, isTopLevel: false, canPop: true),
        AppShellBackAction.closeDrawer,
      );
      expect(
        AppShell.backAction(drawerOpen: true, isTopLevel: true, canPop: true),
        AppShellBackAction.closeDrawer,
      );
    });

    test('a pushed detail (channel chat) pops to its list', () {
      expect(
        AppShell.backAction(drawerOpen: false, isTopLevel: false, canPop: true),
        AppShellBackAction.pop,
      );
    });

    test('a top-level tab backgrounds even though it CAN pop', () {
      // The scanner sits below a top-level tab, so canPop is true, but popping
      // would strand the user on the radio-connect screen.
      expect(
        AppShell.backAction(drawerOpen: false, isTopLevel: true, canPop: true),
        AppShellBackAction.background,
      );
    });

    test('a detail with nothing left to pop backgrounds', () {
      expect(
        AppShell.backAction(
          drawerOpen: false,
          isTopLevel: false,
          canPop: false,
        ),
        AppShellBackAction.background,
      );
    });

    test('a top-level with nothing to pop backgrounds', () {
      expect(
        AppShell.backAction(drawerOpen: false, isTopLevel: true, canPop: false),
        AppShellBackAction.background,
      );
    });
  });

  group('AppShell.canSwipeBack (#1052)', () {
    test('a pushed detail on iOS keeps the edge swipe', () {
      expect(
        AppShell.canSwipeBack(platform: TargetPlatform.iOS, isTopLevel: false),
        isTrue,
      );
    });

    test('a top-level tab on iOS must not swipe back to the scanner', () {
      expect(
        AppShell.canSwipeBack(platform: TargetPlatform.iOS, isTopLevel: true),
        isFalse,
      );
    });

    test('Android keeps routing Back through the shell', () {
      expect(
        AppShell.canSwipeBack(
          platform: TargetPlatform.android,
          isTopLevel: false,
        ),
        isFalse,
      );
    });
  });

  group('system Back wiring', () {
    Widget host(GlobalKey<NavigatorState> navKey) => MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => UiViewStateService())],
      child: MaterialApp(
        navigatorKey: navKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Center(child: Text('HOME'))),
      ),
    );

    Future<void> pushShell(
      WidgetTester tester,
      GlobalKey<NavigatorState> navKey, {
      required bool isTopLevel,
    }) async {
      navKey.currentState!.push(
        MaterialPageRoute(
          builder: (_) => AppShell(
            isTopLevel: isTopLevel,
            selectedIndex: 1,
            onDestinationSelected: (_) {},
            body: const Text('SHELL'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a pushed detail pops back to its list on system Back', (
      tester,
    ) async {
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(host(navKey));
      await pushShell(tester, navKey, isTopLevel: false);
      expect(find.text('SHELL'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('SHELL'), findsNothing, reason: 'popped to the list');
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('a top-level tab does NOT pop on system Back', (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(host(navKey));
      await pushShell(tester, navKey, isTopLevel: true);
      expect(find.text('SHELL'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // moveToBackground is a no-op off Android, so the route stays put.
      expect(find.text('SHELL'), findsOneWidget, reason: 'top-level stays');
    });

    testWidgets('the iOS edge swipe pops a pushed detail', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(host(navKey));
      await pushShell(tester, navKey, isTopLevel: false);

      await tester.dragFrom(const Offset(5, 300), const Offset(500, 0));
      await tester.pumpAndSettle();

      expect(find.text('SHELL'), findsNothing, reason: 'swiped to the list');
      expect(find.text('HOME'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the iOS edge swipe does not pop a top-level tab', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(host(navKey));
      await pushShell(tester, navKey, isTopLevel: true);

      await tester.dragFrom(const Offset(5, 300), const Offset(500, 0));
      await tester.pumpAndSettle();

      expect(find.text('SHELL'), findsOneWidget, reason: 'top-level stays');
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
