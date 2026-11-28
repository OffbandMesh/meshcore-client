// Per-session dismissal of the region-scope banner, keyed by channel PSK (#1258).

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/region_scope_banner_service.dart';

void main() {
  test('a channel banner is not dismissed until dismissed', () {
    final s = RegionScopeBannerService();
    expect(s.isDismissed('pska'), isFalse);
    s.dismiss('pska');
    expect(s.isDismissed('pska'), isTrue);
    expect(s.isDismissed('pskb'), isFalse); // other channels unaffected
  });

  test('dismiss notifies listeners so the banner can hide', () {
    final s = RegionScopeBannerService();
    var notified = 0;
    s.addListener(() => notified++);
    s.dismiss('pska');
    expect(notified, 1);
  });
}
