import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/send_logs_screen.dart';
import 'package:meshcore_open/services/log_upload_service.dart';
import 'package:provider/provider.dart';

class _FakeUploader extends LogUploader {
  _FakeUploader(this.results);
  final List<LogUploadResult> results;
  final List<(Uint8List, String?)> sent = [];

  @override
  Future<LogUploadResult> send(
    Uint8List package, {
    required String platform,
    required String appVersion,
    String? note,
  }) async {
    sent.add((package, note));
    return results.removeAt(0);
  }
}

final _zip = Uint8List.fromList(List.filled(3000, 7));

Future<AppLocalizations> _pump(
  WidgetTester tester, {
  required _FakeUploader uploader,
  LogPackageZipper? zipPackage,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: MeshCoreConnector(),
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SendLogsScreen(
          uploader: uploader,
          zipPackage: zipPackage ?? (_) async => _zip,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byType(SendLogsScreen)));
}

void main() {
  testWidgets('says what is sent, then sends and shows the code', (
    tester,
  ) async {
    final uploader = _FakeUploader([const LogUploadSent('OB-7K2QX')]);
    final l10n = await _pump(tester, uploader: uploader);

    expect(find.text(l10n.sendLogs_consent), findsOneWidget);
    expect(find.text(l10n.sendLogs_size('3 KB')), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'lost a DM');
    await tester.tap(find.text(l10n.sendLogs_send));
    await tester.pumpAndSettle();

    expect(uploader.sent.single.$1, _zip);
    expect(uploader.sent.single.$2, 'lost a DM');
    expect(find.text('OB-7K2QX'), findsOneWidget);
    expect(find.text(l10n.sendLogs_copyCode), findsOneWidget);
    expect(find.text(l10n.sendLogs_send), findsNothing);
  });

  testWidgets('a failure stays on screen and Retry sends the same package', (
    tester,
  ) async {
    final uploader = _FakeUploader([
      const LogUploadFailed(LogUploadFailure.network, 'offline'),
      const LogUploadSent('OB-ABCDE'),
    ]);
    final l10n = await _pump(tester, uploader: uploader);

    await tester.tap(find.text(l10n.sendLogs_send));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    expect(find.text(l10n.sendLogs_failedNetwork), findsOneWidget);

    await tester.tap(find.text(l10n.sendLogs_retry));
    await tester.pumpAndSettle();
    expect(uploader.sent, hasLength(2));
    expect(uploader.sent[1].$1, _zip);
    expect(find.text('OB-ABCDE'), findsOneWidget);
    expect(find.text(l10n.sendLogs_failedNetwork), findsNothing);
  });

  for (final (failure, text) in [
    (
      LogUploadFailure.tooLarge,
      (AppLocalizations l) => l.sendLogs_failedTooLarge,
    ),
    (
      LogUploadFailure.rateLimited,
      (AppLocalizations l) => l.sendLogs_failedRateLimited,
    ),
    (
      LogUploadFailure.refused,
      (AppLocalizations l) => l.sendLogs_failedRefused,
    ),
    (LogUploadFailure.server, (AppLocalizations l) => l.sendLogs_failedServer),
  ]) {
    testWidgets('${failure.name} says why', (tester) async {
      final l10n = await _pump(
        tester,
        uploader: _FakeUploader([LogUploadFailed(failure, 'x')]),
      );
      await tester.tap(find.text(l10n.sendLogs_send));
      await tester.pumpAndSettle();
      expect(find.text(text(l10n)), findsOneWidget);
    });
  }

  testWidgets('with no logs there is nothing to send', (tester) async {
    final uploader = _FakeUploader([]);
    final l10n = await _pump(
      tester,
      uploader: uploader,
      zipPackage: (_) async => null,
    );
    expect(find.text(l10n.sendLogs_noLogs), findsOneWidget);
    expect(find.text(l10n.sendLogs_send), findsNothing);
  });

  testWidgets('a package that cannot be built says so', (tester) async {
    final l10n = await _pump(
      tester,
      uploader: _FakeUploader([]),
      zipPackage: (_) async => throw StateError('disk'),
    );
    expect(find.text(l10n.sendLogs_failedPrepare), findsOneWidget);
    expect(find.text(l10n.sendLogs_send), findsNothing);
  });
}
