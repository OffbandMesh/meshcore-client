import 'package:flutter/material.dart';

/// Runs a settings-persist [action] and surfaces a dismissible error SnackBar if
/// it throws, instead of dropping the returned Future and swallowing the error
/// (no silent failures, #28).
///
/// Call sites intentionally don't await the returned Future: this function never
/// rethrows (it catches internally), so dropping it is safe. The
/// [ScaffoldMessenger] is captured before the await, so the error still shows
/// even when the triggering widget (e.g. a picker dialog) is popped immediately
/// after.
///
/// [message] is English-only for now; localizing it is part of the separate
/// settings l10n sweep noted on #28.
Future<void> persistSetting(
  BuildContext context,
  Future<void> Function() action, {
  String message = 'Could not save that setting. Please try again.',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
  } catch (_) {
    messenger.showSnackBar(
      SnackBar(
        content: GestureDetector(
          onTap: () => messenger.hideCurrentSnackBar(),
          child: Text(message),
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        dismissDirection: DismissDirection.down,
      ),
    );
  }
}
