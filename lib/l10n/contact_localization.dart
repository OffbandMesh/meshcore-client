import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import 'app_localizations.dart';

/// UI-level localization helpers for [Contact].
///
/// Kept out of the model layer so `Contact` does not depend on
/// `AppLocalizations`. Use these from widgets/screens; for logs and
/// non-UI export use `Contact.typeLabelRaw`.
extension ContactLocalization on Contact {
  String typeLabel(AppLocalizations l10n) {
    switch (type) {
      case advTypeChat:
        return l10n.contact_typeChat;
      case advTypeRepeater:
        return l10n.contact_typeRepeater;
      case advTypeRoom:
        return l10n.contact_typeRoom;
      case advTypeSensor:
        return l10n.contact_typeSensor;
      default:
        return l10n.contact_typeUnknown;
    }
  }

  String pathLabel(AppLocalizations l10n) {
    // A zero-hop override was the retired "Direct" mode (#1223 R2). It is not
    // an override any more, so the label describes the radio's own path rather
    // than claiming a forced route that nothing enforces.
    final int? override = pathOverride == 0 ? null : pathOverride;

    if (override != null) {
      if (override < 0) return l10n.chat_floodForced;
      return l10n.chat_hopsForced(override);
    }
    if (pathLength < 0) return l10n.channelPath_floodPath;
    if (pathLength == 0) return l10n.chat_direct;
    return l10n.chat_hopsCount(pathLength);
  }
}
