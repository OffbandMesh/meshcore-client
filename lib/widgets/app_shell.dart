import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/ui_view_state_service.dart';
import 'quick_switch_bar.dart';

/// Shared shell for the primary views (Contacts / Channels / Map).
///
/// Owns the bottom [QuickSwitchBar] that each view previously mounted itself,
/// plus the left nav drawer: a transient slide-out on narrow layouts, and a
/// dockable pane that can be pinned open on wide ones.
///
/// The bottom bar stays a bottom bar at every width; it never becomes a rail.
class AppShell extends StatefulWidget {
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

  /// App-level actions, pinned to the bottom of the panel. These are not
  /// contextual, which is why they were duplicated in three screens' overflow
  /// menus before. Screen-level actions stay in their own overflow menu.
  final VoidCallback? onDisconnect;
  final VoidCallback? onSettings;

  const AppShell({
    super.key,
    required this.body,
    this.selectedIndex,
    this.onDestinationSelected,
    this.appBar,
    this.appBarBuilder,
    this.floatingActionButton,
    this.drawerContent,
    this.onDisconnect,
    this.onSettings,
    this.contactsUnreadCount = 0,
    this.channelsUnreadCount = 0,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// System back, in priority order:
  ///   1. an open drawer closes,
  ///   2. otherwise pop the route (a pushed chat returns to its list),
  ///   3. otherwise hand back to the OS, so Android returns to the home
  ///      screen or the previous app rather than sitting on a dead press.
  ///
  /// Screens previously did this with `PopScope(canPop: !isConnected)`, which
  /// swallowed back entirely while connected: the drawer would not close and
  /// the app would never background.
  void _handleBack() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold?.isDrawerOpen ?? false) {
      scaffold!.closeDrawer();
      return;
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= AppShell.wideBreakpoint;
          final pinned =
              isWide && context.watch<UiViewStateService>().navDrawerPinned;

          return pinned
              ? _buildPinned(context)
              : _buildTransient(context, isWide);
        },
      ),
    );
  }

  /// Null on detail screens, which show the panel but no bottom bar.
  Widget? _bottomBar() {
    final index = widget.selectedIndex;
    final onSelected = widget.onDestinationSelected;
    if (index == null || onSelected == null) return null;
    return SafeArea(
      top: false,
      child: QuickSwitchBar(
        selectedIndex: index,
        onDestinationSelected: onSelected,
        contactsUnreadCount: widget.contactsUnreadCount,
        channelsUnreadCount: widget.channelsUnreadCount,
      ),
    );
  }

  PreferredSizeWidget? _appBar(BuildContext context, bool pinned) {
    return widget.appBarBuilder?.call(context, pinned) ?? widget.appBar;
  }

  /// Wide + pinned: the panel is laid out beside the body, not overlaid.
  Widget _buildPinned(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: _appBar(context, true),
      body: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: AppShell._drawerWidth,
              child: _NavPanel(
                isWide: true,
                content: widget.drawerContent,
                onDisconnect: widget.onDisconnect,
                onSettings: widget.onSettings,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: widget.body),
          ],
        ),
      ),
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: _bottomBar(),
    );
  }

  /// Narrow, or wide-but-unpinned: standard transient drawer. Scaffold injects
  /// the hamburger into the app bar automatically.
  Widget _buildTransient(BuildContext context, bool isWide) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: _appBar(context, false),
      drawer: Drawer(
        width: AppShell._drawerWidth,
        child: _NavPanel(
          isWide: isWide,
          content: widget.drawerContent,
          onDisconnect: widget.onDisconnect,
          onSettings: widget.onSettings,
        ),
      ),
      body: widget.body,
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: _bottomBar(),
    );
  }
}

/// Drawer contents. The pin control appears only on wide layouts, where
/// docking the panel open is useful.
class _NavPanel extends StatelessWidget {
  final bool isWide;
  final Widget? content;
  final VoidCallback? onDisconnect;
  final VoidCallback? onSettings;

  const _NavPanel({
    required this.isWide,
    this.content,
    this.onDisconnect,
    this.onSettings,
  });

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
          if (onDisconnect != null || onSettings != null) ...[
            const Divider(height: 1),
            _Footer(onDisconnect: onDisconnect, onSettings: onSettings),
          ],
        ],
      ),
    );
  }
}

/// App-level actions pinned to the bottom of the panel.
class _Footer extends StatelessWidget {
  final VoidCallback? onDisconnect;
  final VoidCallback? onSettings;

  const _Footer({this.onDisconnect, this.onSettings});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Row(
        children: [
          if (onDisconnect != null)
            Expanded(
              child: TextButton.icon(
                // Kept visually distinct: this drops the radio connection,
                // and it was a red menu entry before the move.
                style: TextButton.styleFrom(foregroundColor: colors.error),
                icon: const Icon(Icons.logout, size: 18),
                label: Text(l10n.common_disconnect),
                onPressed: onDisconnect,
              ),
            ),
          if (onSettings != null)
            Expanded(
              child: TextButton.icon(
                icon: const Icon(Icons.settings, size: 18),
                label: Text(l10n.settings_title),
                onPressed: onSettings,
              ),
            ),
        ],
      ),
    );
  }
}
