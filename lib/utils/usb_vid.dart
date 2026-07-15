/// USB vendor-ID helpers for gating the desktop serial open sequence.
///
/// The DTR low→high pulse in the USB open path is a "fresh connection" signal
/// nRF52 boards need to reconnect after an unclean disconnect. But on ESP32
/// USB-Serial/JTAG chips (VID 303A: C6/H2/S3-HWCDC) the ROM maps DTR/RTS onto
/// EN/BOOT, so the pulse resets the chip into ROM download mode mid-open and
/// wedges it until a physical reset. We gate the pulse by vendor ID. (#244/#245)
library;

/// Adafruit — nRF52 boards (RAK4631 etc.). Needs the DTR edge to reconnect.
const int usbVidAdafruitNrf52 = 0x239A;

/// Espressif — ESP32 USB-Serial/JTAG. The DTR pulse resets it into ROM.
const int usbVidEspressif = 0x303A;

final RegExp _vidWindows = RegExp(r'VID_([0-9A-Fa-f]{4})');
final RegExp _vidUnix = RegExp(r'VID:PID=([0-9A-Fa-f]{4}):[0-9A-Fa-f]{4}');

/// Parses a USB vendor ID (0..0xFFFF) from a flserial `hardware_id` string, or
/// null if none is present. Handles both formats flserial emits:
///  - Windows (SetupAPI `SPDRP_HARDWAREID`): `USB\VID_303A&PID_1001&...`
///  - macOS / Linux (pyserial-style):        `USB VID:PID=303a:1001 SNR=...`
int? parseUsbVid(String hardwareId) {
  final win = _vidWindows.firstMatch(hardwareId);
  if (win != null) return int.parse(win.group(1)!, radix: 16);
  final unix = _vidUnix.firstMatch(hardwareId);
  if (unix != null) return int.parse(unix.group(1)!, radix: 16);
  return null;
}
