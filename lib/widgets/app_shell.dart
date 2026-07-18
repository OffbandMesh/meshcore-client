import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ui_view_state_service.dart';
import 'quick_switch_bar.dart';

/// Shared shell for the primary views (Contacts / Channels / Map).
///
/// Owns the bottom [QuickSwitchBar] that each view previously mounted itself,
/// plus the left nav drawer: a transient slide-out on narrow layouts, and a
/// dockable pane that can be pinned open on wide ones.
///
/// The bottom bar stays a bottom bar at every width; it never becomes a rail.
class AppShell extends StatelessWidget {
  static const double wideBreakpoint = 720;
  static const double _drawerWidth = 300;

  /// Bottom bar tab. Null on pushed detail screens (a channel chat), which
  /// carry the nav panel but no bottom bar.
  final int? selectedIndex;
  final ValueChanged<int>? onDestinationSelected;
  final int contactsUnreadCount;
  final int channelsUnreadCount;

  final PreferredSizeWidget? appBar;

  /// App bar that needs to know whether the panel is docked, so a pushed
  /// screen can drop its hamburger when the panel is already pinned open.
  /// Takes precedence over [appBar].
  final PreferredSizeWidget Function(BuildContext context, bool pinned)?
  appBarBuilder;

  final Widget body;
  final Widget? floatingActionButton;

  /// List content for the active view. Null renders an empty drawer body.
  final Widget? drawerContent;

  const AppShell({
    super.key,
    required this.body,
    this.selectedIndex,
    this.onDestinationSelected,
    this.appBar,
    this.appBarBuilder,
    this.floatingActionButton,
    this.drawerContent,
    this.contactsUnreadCount = 0,
    this.channelsUnreadCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= wideBreakpoint;
        final pinned =
            isWide && context.watch<UiViewStateService>().navDrawerPinned;

        return pinned
            ? _buildPinned(context)
            : _buildTransient(context, isWide);
      },
    );
  }

  /// Null on detail screens, which show the panel but no bottom bar.
  Widget? _bottomBar() {
    final index = selectedIndex;
    final onSelected = onDestinationSelected;
    if (index == null || onSelected == null) return null;
    return SafeArea(
      top: false,
      child: QuickSwitchBar(
        selectedIndex: index,
        onDestinationSelected: onSelected,
        contactsUnreadCount: contactsUnreadCount,
        channelsUnreadCount: channelsUnreadCount,
      ),
    );
  }

  PreferredSizeWidget? _appBar(BuildContext context, bool pinned) {
    return appBarBuilder?.call(context, pinned) ?? appBar;
  }

  /// Wide + pinned: the panel is laid out beside the body, not overlaid.
  Widget _buildPinned(BuildContext context) {
    return Scaffold(
      appBar: _appBar(context, true),
      body: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: _drawerWidth,
              child: _NavPanel(isWide: true, content: drawerContent),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      ),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: _bottomBar(),
    );
  }

  /// Narrow, or wide-but-unpinned: standard transient drawer. Scaffold injects
  /// the hamburger into the app bar automatically.
  Widget _buildTransient(BuildContext context, bool isWide) {
    return Scaffold(
      appBar: _appBar(context, false),
      drawer: Drawer(
        width: _drawerWidth,
        child: _NavPanel(isWide: isWide, content: drawerContent),
      ),
      body: body,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: _bottomBar(),
    );
  }
}

/// Drawer contents. The pin control appears only on wide layouts, where
/// docking the panel open is useful.
class _NavPanel extends StatelessWidget {
  final bool isWide;
  final Widget? content;

  const _NavPanel({required this.isWide, this.content});

  @override
  Widget build(BuildContext context) {
    final uiState = context.watch<UiViewStateService>();
    final pinned = uiState.navDrawerPinned;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isWide)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      MaterialLocalizations.of(context).drawerLabel,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    ),
                    isSelected: pinned,
                    tooltip: pinned ? 'Unpin panel' : 'Pin panel open',
                    onPressed: () => uiState.setNavDrawerPinned(!pinned),
                  ),
                ],
              ),
            ),
          if (isWide) const Divider(height: 1),
          Expanded(child: content ?? const SizedBox.shrink()),
        ],
      ),
    );
  }
}
