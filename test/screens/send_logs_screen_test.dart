import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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

Future<void> _tapSend(WidgetTester tester, AppLocalizations l10n) async {
  await tester.ensureVisible(find.text(l10n.sendLogs_send));
  await tester.pumpAndSettle();
  await tester.tap(find.text(l10n.sendLogs_send));
  await tester.pumpAndSettle();
}

Uint8List _realZip() => ZipEncoder().encodeBytes(
  Archive()..addFile(ArchiveFile.string('manifest.json', '{"format": 1}')),
);

void main() {
  testWidgets('name and email are sealed inside the package, not the note', (
    tester,
  ) async {
    final zip = _realZip();
    final uploader = _FakeUploader([const LogUploadSent('OB-7K2QX')]);
    final l10n = await _pump(
      tester,
      uploader: uploader,
      zipPackage: (_) async => zip,
    );

    await tester.enterText(
      find.widgetWithText(TextField, l10n.sendLogs_nameLabel),
      ' Pottsytron ',
    );
    await tester.enterText(
      find.widgetWithText(TextField, l10n.sendLogs_emailLabel),
      'ben@example.com',
    );
    await _tapSend(tester, l10n);

    final (sent, note) = uploader.sent.single;
    expect(note, isEmpty);
    final files = ZipDecoder().decodeBytes(sent);
    expect(files.findFile('manifest.json'), isNotNull);
    final sender = jsonDecode(
      utf8.decode(files.findFile('sender.json')!.content as List<int>),
    );
    expect(sender, {'name': 'Pottsytron', 'email': 'ben@example.com'});
  });

  testWidgets('a mistyped email blocks the send and says why', (tester) async {
    final uploader = _FakeUploader([const LogUploadSent('OB-7K2QX')]);
    final l10n = await _pump(tester, uploader: uploader);
    final email = find.widgetWithText(TextField, l10n.sendLogs_emailLabel);

    await tester.enterText(email, 'ben@example');
    await tester.pump();
    expect(find.text(l10n.sendLogs_emailInvalid), findsOneWidget);
    await tester.ensureVisible(find.text(l10n.sendLogs_send));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.sendLogs_send), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(uploader.sent, isEmpty);

    await tester.enterText(email, '');
    await tester.pump();
    expect(find.text(l10n.sendLogs_emailInvalid), findsNothing);
    await _tapSend(tester, l10n);
    expect(uploader.sent, hasLength(1));
  });

  testWidgets('says what is sent, then sends and shows the code', (
    tester,
  ) async {
    final uploader = _FakeUploader([const LogUploadSent('OB-7K2QX')]);
    final l10n = await _pump(tester, uploader: uploader);

    expect(find.text(l10n.sendLogs_consent), findsOneWidget);
    expect(find.text(l10n.sendLogs_size('3 KB')), findsOneWidget);
    expect(find.text(l10n.sendLogs_contactNote), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, l10n.sendLogs_noteLabel),
      'lost a DM',
    );
    await _tapSend(tester, l10n);

    // No name or email: the package goes out exactly as built.
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

    await _tapSend(tester, l10n);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text(l10n.sendLogs_failedNetwork), findsOneWidget);

    await tester.ensureVisible(find.text(l10n.sendLogs_retry));
    await tester.pumpAndSettle();
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
      await _tapSend(tester, l10n);
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
