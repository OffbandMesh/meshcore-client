import 'dart:io';

/// Queries the macOS IOKit registry via [ioreg] to build a map of serial port
/// callout device paths to human-readable USB device names.
///
/// The [flserial] native library uses the deprecated [IOUSBDevice] IOKit class
/// to resolve device names, but macOS 10.15+ renamed it to [IOUSBHostDevice].
/// As a result flserial always returns "n/a" for USB product/vendor info on
/// modern macOS. This utility bypasses that limitation by invoking ioreg
/// directly and parsing its output.
///
/// Returns a Map of e.g. `"/dev/cu.usbmodem1101"` → `"Nordic NRF52 DK"`.
/// Devices without a USB product name are not included in the map.
Future<Map<String, String>> queryMacOsUsbDeviceNames() async {
  assert(Platform.isMacOS);
  try {
    final result = await Process.run('ioreg', [
      '-r',
      '-c',
      'IOUSBHostDevice',
      '-l',
    ], stdoutEncoding: const SystemEncoding());
    if (result.exitCode != 0) return const <String, String>{};
    return _parseIoregOutput(result.stdout as String);
  } catch (_) {
    return const <String, String>{};
  }
}

Map<String, String> _parseIoregOutput(String output) {
  final lines = output.split('\n');
  final result = <String, String>{};

  // We accumulate the current device block's properties.
  // A new block starts at a line beginning with "+-o " which indicates a
  // top-level IOUSBHostDevice entry in the ioreg tree.
  String? currentVendor;
  String? currentProduct;
  final List<String> currentPorts = <String>[];

  void flushBlock() {
    if (currentPorts.isNotEmpty &&
        (currentVendor != null || currentProduct != null)) {
      final parts = <String>[
        if (currentVendor != null && currentVendor!.isNotEmpty) currentVendor!,
        if (currentProduct != null && currentProduct!.isNotEmpty)
          currentProduct!,
      ];
      final name = parts.join(' ');
      for (final port in currentPorts) {
        result[port] = name;
      }
    }
    currentVendor = null;
    currentProduct = null;
    currentPorts.clear();
  }

  for (final line in lines) {
    // A new top-level device block begins here.
    if (line.startsWith('+-o ')) {
      flushBlock();
      continue;
    }
    // USB Product Name (appears at multiple depths in the tree, first wins)
    final productMatch = _kProductName.firstMatch(line);
    if (productMatch != null && currentProduct == null) {
      currentProduct = productMatch.group(1)?.trim();
      continue;
    }
    // USB Vendor Name
    final vendorMatch = _kVendorName.firstMatch(line);
    if (vendorMatch != null && currentVendor == null) {
      currentVendor = vendorMatch.group(1)?.trim();
      continue;
    }
    // IOCalloutDevice, the /dev/cu.xxx path our app uses
    final calloutMatch = _kCalloutDevice.firstMatch(line);
    if (calloutMatch != null) {
      final port = calloutMatch.group(1)?.trim();
      if (port != null && port.isNotEmpty) {
        currentPorts.add(port);
      }
    }
  }
  flushBlock();
  return result;
}

final RegExp _kProductName = RegExp(r'"USB Product Name" = "([^"]*)"');
final RegExp _kVendorName = RegExp(r'"USB Vendor Name" = "([^"]*)"');
final RegExp _kCalloutDevice = RegExp(r'"IOCalloutDevice" = "([^"]*)"');
