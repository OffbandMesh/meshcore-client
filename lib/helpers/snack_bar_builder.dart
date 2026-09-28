import 'package:flutter/material.dart';

import '../widgets/top_toast.dart';

/// Shows a transient notification that dismisses on tap, on an upward swipe,
/// or after [duration].
///
/// Kept under its original name so existing call sites are unchanged; the
/// notification itself moved from a bottom [SnackBar] to a top-anchored
/// overlay (#638), because the bottom placement covered the chat composer.
void showDismissibleSnackBar(
  BuildContext context, {
  required Widget content,
  Color? backgroundColor,
  Duration? duration,
  bool? persist,
}) {
  TopToast.show(
    context,
    content: content,
    backgroundColor: backgroundColor,
    duration: duration ?? TopToast.defaultDuration,
    persist: persist ?? false,
  );
}
