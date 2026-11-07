import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:url_launcher/url_launcher.dart';

/// The OpenStreetMap licence credit every map must show, always visible and
/// never behind a toggle (OSMF tile policy, #1111). Place it as the last
/// child of a [FlutterMap] so map layers can't paint over it.
class OsmAttribution extends StatelessWidget {
  const OsmAttribution({super.key, this.alignment = Alignment.bottomRight});

  static const String text = 'OpenStreetMap contributors';
  static final Uri copyrightUri = Uri.parse(
    'https://www.openstreetmap.org/copyright',
  );

  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return SimpleAttributionWidget(
      alignment: alignment,
      source: const Text(text),
      onTap: () =>
          launchUrl(copyrightUri, mode: LaunchMode.externalApplication),
    );
  }
}
