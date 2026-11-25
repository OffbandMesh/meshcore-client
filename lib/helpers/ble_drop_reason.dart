import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// The log line written when the OS reports a BLE link drop (#1186), so a user
/// log says why the link ended instead of only that it did.
///
/// iOS, macOS and Android report a reason code. Windows, Linux and web report
/// none (#1187), and the line says so rather than calling it unknown.
String describeBleDrop({
  required DisconnectReason? reason,
  required String platform,
  required bool platformReportsReason,
  required Duration sinceLastRx,
  required AppLifecycleState? lifecycle,
}) {
  final code = reason?.code;
  final String why;
  if (!platformReportsReason) {
    why = 'reason not available on $platform';
  } else if (code == null) {
    why = '$platform gave no reason code';
  } else {
    final description = reason!.description;
    why =
        '${reason.platform.name}-code $code'
        '${description == null || description.isEmpty ? '' : ': $description'}';
  }
  final app = lifecycle == null
      ? 'app state not reported'
      : 'app ${lifecycle.name}';
  return 'BLE link dropped by $platform ($why); '
      'last frame from the radio ${sinceLastRx.inSeconds}s ago; $app';
}
