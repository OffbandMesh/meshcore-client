import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/radio_preset.dart';
import 'package:meshcore_open/services/config_source_service.dart';
import 'package:meshcore_open/services/radio_preset_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Fetches the real preset files from config-profiles (#748). Every other
// preset test fakes the network, so a 404 on main passed them all and the
// owner saw "Couldn't update presets" on a test build twice. This one fails
// whenever the app's own refresh would.
void main() {
  test(
    'refresh from config-profiles succeeds with no error',
    () async {
      SharedPreferences.setMockInitialValues({});
      final service = RadioPresetService(
        prefs: await SharedPreferences.getInstance(),
        loadAsset: (_) async => throw StateError('bundled copies not used'),
      );
      addTearDown(service.dispose);

      final ok = await service.refresh();

      expect(service.refreshError, isNull, reason: 'refresh reported an error');
      expect(ok, isTrue);
      expect(service.skipped, 0);
      final sources = service.presets.map((p) => p.source).toSet();
      expect(sources, {RadioPresetSource.meshcore, RadioPresetSource.offband});
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a missing file on config-profiles is reported, not ignored',
    () async {
      final source = ConfigSourceService();
      addTearDown(source.dispose);
      await expectLater(
        source.fetchText('${kRadioPresetBaseUrl}missing-748.json'),
        throwsA(
          isA<ConfigSourceException>().having(
            (e) => '$e',
            'message',
            contains('HTTP 404'),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
