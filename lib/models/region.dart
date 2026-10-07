import 'dart:typed_data';

import 'package:meshcore_open/helpers/region_key.dart';

/// A flood region as discovered from a repeater.
///
/// [name] is the `#`-stripped region name the firmware reports over the air.
/// Value equality is by name so a discovery service can dedupe replies.
class Region {
  final String name;

  const Region(this.name);

  /// A wildcard region (matches a family of names) rather than a single one.
  bool get isWildcard => name.contains('*');

  /// A private region whose key is not derivable from its name.
  bool get isPrivate => isPrivateRegionName(name);

  /// The 16-byte transport key for this region, or null when it is private
  /// or blank.
  Uint8List? get transportKey => transportKeyForName(name);

  @override
  bool operator ==(Object other) => other is Region && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'Region($name)';
}
