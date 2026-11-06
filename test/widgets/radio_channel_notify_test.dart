import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/offband_channel_notify.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/widgets/radio_channel_notify.dart';

/// #544 Epic C task C3: what a channel row says the RADIO will actually do.
///
/// The owner's call (2026-11-03) was to show the composed result rather than
/// the raw stored byte. This pins the composition, because getting it wrong is
/// a lie to the user rather than a cosmetic slip: a muted radio showing a
/// channel as "All messages" is exactly the confusion this feature exists to
/// end.
///
/// Firmware's rules, per AM 1406: a channel with a mode set decides for
/// itself; a channel with no mode falls back to the device-wide scope; a
/// device scope of None overrides even a channel that is set.
void main() {
  /// Resolves [radioChannelNotifyEffective] inside a localized context.
  Future<String?> effective(
    WidgetTester tester,
    RadioChannelNotify? mode,
    DeviceNotifyScope? scope,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            result = radioChannelNotifyEffective(context, mode, scope);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('a set mode decides for itself', (tester) async {
    expect(
      await effective(tester, RadioChannelNotify.all, DeviceNotifyScope.self),
      'All messages',
    );
    expect(
      await effective(
        tester,
        RadioChannelNotify.mentions,
        DeviceNotifyScope.all,
      ),
      'Mentions only',
    );
    expect(
      await effective(tester, RadioChannelNotify.off, DeviceNotifyScope.all),
      'Off',
    );
  });

  testWidgets('an unset mode follows the device scope, named', (tester) async {
    expect(
      await effective(tester, RadioChannelNotify.unset, DeviceNotifyScope.self),
      'Follows the radio: Self',
    );
    expect(
      await effective(tester, RadioChannelNotify.unset, DeviceNotifyScope.all),
      'Follows the radio: All',
    );
  });

  testWidgets('a device scope of None overrides even a set channel', (
    tester,
  ) async {
    // The case that makes this composition load-bearing. A user who has muted
    // the radio must not be told a channel is on "All messages".
    expect(
      await effective(tester, RadioChannelNotify.all, DeviceNotifyScope.none),
      'Silent: the radio is set to None',
    );
    expect(
      await effective(
        tester,
        RadioChannelNotify.mentions,
        DeviceNotifyScope.none,
      ),
      'Silent: the radio is set to None',
    );
    expect(
      await effective(tester, RadioChannelNotify.unset, DeviceNotifyScope.none),
      'Silent: the radio is set to None',
    );
  });

  testWidgets('nothing is claimed before the radio has answered', (
    tester,
  ) async {
    // Null means "cannot be known yet", and the caller shows a reading state.
    // It must never resolve to a mode we invented.
    expect(await effective(tester, null, DeviceNotifyScope.all), isNull);
    expect(await effective(tester, null, null), isNull);
    expect(
      await effective(tester, RadioChannelNotify.unset, null),
      isNull,
      reason: 'unset with an unknown scope composes to nothing truthful',
    );
  });

  testWidgets('a set mode resolves without the scope being known', (
    tester,
  ) async {
    // A channel that decides for itself does not need the device scope, so it
    // is shown immediately rather than waiting on a second read.
    expect(await effective(tester, RadioChannelNotify.off, null), 'Off');
  });
}
