import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/utils/usb_vid.dart';

void main() {
  group('parseUsbVid', () {
    test('Windows SPDRP_HARDWAREID format', () {
      expect(
        parseUsbVid(r'USB\VID_303A&PID_1001&MI_00\8&25728F34&0&0000'),
        0x303A,
      );
      expect(
        parseUsbVid(r'USB\VID_239A&PID_8029&MI_00\8&6C3483E&0&0000'),
        0x239A,
      );
    });

    test('macOS / Linux pyserial format', () {
      expect(parseUsbVid('USB VID:PID=303a:1001 SNR=1234'), 0x303A);
      expect(parseUsbVid('USB VID:PID=239a:8029 LOCATION=1-1'), 0x239A);
    });

    test('hex is case-insensitive', () {
      expect(parseUsbVid(r'USB\VID_303a&PID_1001'), 0x303A);
      expect(parseUsbVid('USB VID:PID=239A:8029'), 0x239A);
    });

    test('no VID present returns null', () {
      expect(parseUsbVid('n/a'), isNull);
      expect(parseUsbVid('USB Serial Device'), isNull);
      expect(parseUsbVid(''), isNull);
      expect(parseUsbVid('COM23'), isNull);
    });

    test('known vendor-ID constants', () {
      expect(usbVidAdafruitNrf52, 0x239A);
      expect(usbVidEspressif, 0x303A);
    });
  });
}
