import 'package:flutter/material.dart';

/// The radio's refusal of a device-UI write, shown until dismissed rather than
/// flashed: an error the user cannot finish reading is not a surfaced error.
class DeviceUiErrorBanner extends StatelessWidget {
  const DeviceUiErrorBanner({
    super.key,
    required this.message,
    required this.onDismiss,
    this.margin = const EdgeInsets.all(12),
  });

  final String message;
  final VoidCallback onDismiss;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: scheme.onErrorContainer),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
