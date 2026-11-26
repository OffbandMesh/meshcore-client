import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/utils/log_redactor.dart';

/// Every code the app can send has to be reviewed for passwords and PINs
/// before it ships (#1192). These tests read the source, so a new `cmd*`
/// constant or 0xC5 sub-code fails CI until someone classifies it.
final _constant = RegExp(
  r'const int ((?:cmd|offbandUi)\w*) = (0x[0-9A-Fa-f]+|\d+);',
);

Map<String, int> _constants(String prefix) {
  final found = <String, int>{};
  for (final file in Directory('lib').listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.dart')) continue;
    for (final m in _constant.allMatches(file.readAsStringSync())) {
      if (!m.group(1)!.startsWith(prefix)) continue;
      found[m.group(1)!] = int.parse(m.group(2)!);
    }
  }
  return found;
}

/// 0xC5 device UI sub-codes, reviewed for #1192: none carries a password or
/// a PIN (the battery "pin" flag pins a charge reading, it is not a PIN).
const _deviceUiSubCodesReviewed = {
  'offbandUiScopeGet',
  'offbandUiScopeSet',
  'offbandUiMatrixGet',
  'offbandUiMatrixSet',
  'offbandUiDisplayGet',
  'offbandUiDisplaySet',
  'offbandUiLedGet',
  'offbandUiLedSet',
  'offbandUiSlotGet',
  'offbandUiSlotSet',
  'offbandUiChannelTuneGet',
  'offbandUiChannelTuneSet',
  'offbandUiGpsGet',
  'offbandUiGpsSet',
  'offbandUiEventToneGet',
  'offbandUiEventToneSet',
  'offbandUiTunePlay',
  'offbandUiSlotRead',
  'offbandUiScreenGet',
  'offbandUiTextSet',
  'offbandUiScreenOffSet',
  'offbandUiTimeZoneSet',
  'offbandUiBatterySet',
  'offbandUiChannelNotifyGet',
  'offbandUiChannelNotifySet',
  'offbandUiRotationGet',
  'offbandUiRotationSet',
  'offbandUiInfoGet',
  'offbandUiErr',
  'offbandUiErrReasonMalformed',
};

void main() {
  test('every command code the app defines is classified', () {
    final commands = _constants('cmd');
    expect(commands, isNotEmpty);
    final unclassified = {
      for (final e in commands.entries)
        if (!sentFrameSecrets.containsKey(e.value)) e.key: e.value,
    };
    expect(unclassified, isEmpty, reason: 'add these to sentFrameSecrets');
  });

  test('every 0xC5 sub-code has been reviewed', () {
    final subCodes = _constants('offbandUi').keys.toSet();
    expect(subCodes, isNotEmpty);
    expect(subCodes.difference(_deviceUiSubCodesReviewed), isEmpty);
  });

  test('the codes that carry passwords, PINs or keys are not marked clean', () {
    final carriers = _constants('cmd');
    for (final name in [
      'cmdSendLogin',
      'cmdSetDevicePin',
      'cmdImportPrivateKey',
      'cmdSendTxtMsg',
      'cmdRunCliCommand',
      'cmdConfig',
    ]) {
      expect(
        sentFrameSecrets[carriers[name]],
        isNot(SentSecret.none),
        reason: name,
      );
    }
  });
}
