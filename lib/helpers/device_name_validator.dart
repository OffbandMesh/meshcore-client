// Mirrors the firmware's `set name` character rejection on the client (#885,
// interop plan F2/E2.1). The companion CommonCLI rejects these characters in a
// device name [verified: companion built-ins, INVESTIGATION.md section A], and
// a name carrying one comes back as a cryptic `ERROR` from the device. Catching
// it client-side lets the UI say exactly what is wrong before anything is sent.
//
// The device stays the authority: this is a convenience check, not a
// replacement for the device's own validation.

/// Characters the firmware's `set name` rejects.
const List<String> forbiddenDeviceNameChars = <String>[
  '[',
  ']',
  '\\',
  ':',
  ',',
  '?',
  '*',
];

/// The distinct forbidden characters present in [name], in the order they
/// appear in [forbiddenDeviceNameChars]. Empty when the name is valid.
List<String> forbiddenCharsIn(String name) =>
    forbiddenDeviceNameChars.where(name.contains).toList();

/// True when [name] carries none of the forbidden characters.
bool isValidDeviceName(String name) => forbiddenCharsIn(name).isEmpty;
