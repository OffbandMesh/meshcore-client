import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/widgets/composer_budget_notice.dart';

/// #684: a composer whose byte budget has collapsed must say so, instead of
/// presenting a field that silently rejects every keystroke (#592 was reported
/// three times as "the keyboard doesn't respond"). Equally it must stay
/// invisible the rest of the time, or it becomes noise that teaches people to
/// ignore it.
Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  group('stays invisible when it should (#684)', () {
    testWidgets('healthy budget renders nothing', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const ComposerBudgetNotice(
            maxBytes: 148, // a channel composer on a 172-byte frame budget
            transport: MeshCoreTransportType.bluetooth,
            isConnected: true,
          ),
        ),
      );

      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(find.byIcon(Icons.info_outline), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('collapsed budget while DISCONNECTED renders nothing', (
      tester,
    ) async {
      // The regression the pre-PR review caught. While disconnected the
      // transport still reads bluetooth and there is no device, so the budget
      // collapses to the same floor an unreported MTU produces. Without the
      // gate this banner appeared on every disconnect and blamed the link for
      // a small packet size when there was no link at all.
      await tester.pumpWidget(
        _wrap(
          const ComposerBudgetNotice(
            maxBytes: 0,
            transport: MeshCoreTransportType.bluetooth,
            isConnected: false,
          ),
        ),
      );

      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(find.byType(Text), findsNothing);
    });
  });

  group('explains itself when the budget has collapsed (#684)', () {
    testWidgets('zero budget reads as a failure, not a hint', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const ComposerBudgetNotice(
            maxBytes: 0,
            transport: MeshCoreTransportType.bluetooth,
            isConnected: true,
          ),
        ),
      );

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsNothing);
      // Names the cause in plain words rather than exposing byte arithmetic.
      expect(find.textContaining('Bluetooth'), findsOneWidget);
    });

    testWidgets('a small but nonzero budget is stated, not alarmed about', (
      tester,
    ) async {
      // 4 bytes is the measured DM budget at the unknown-MTU floor. The link
      // works, it is just tiny, so this must not render as an error.
      await tester.pumpWidget(
        _wrap(
          const ComposerBudgetNotice(
            maxBytes: 4,
            transport: MeshCoreTransportType.bluetooth,
            isConnected: true,
          ),
        ),
      );

      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      // The actual number is surfaced so the user knows what they have.
      expect(find.textContaining('4'), findsOneWidget);
    });

    testWidgets('a non-bluetooth transport does not blame Bluetooth', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ComposerBudgetNotice(
            maxBytes: 0,
            transport: MeshCoreTransportType.usb,
            isConnected: true,
          ),
        ),
      );

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.textContaining('Bluetooth'), findsNothing);
    });
  });
}
