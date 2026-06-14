import 'package:flutter/material.dart';

/// One entry in the responsive settings shell: an icon, a title, an optional
/// subtitle, and a builder for the category's detail pane.
class SettingsCategory {
  final IconData icon;
  final String title;
  final String? subtitle;
  final WidgetBuilder builder;

  const SettingsCategory({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.builder,
  });
}

/// Responsive master-detail container for settings.
///
/// Wide layouts (>= [_wideBreakpoint] logical pixels) show a pinned category
/// rail beside the selected detail pane. Narrow layouts show the category list
/// and push the detail onto the navigator. Same categories, same code, every
/// platform — the layout is chosen from the available width, not the OS.
class SettingsShell extends StatefulWidget {
  final String title;
  final List<SettingsCategory> categories;
  final PreferredSizeWidget? appBarBottom;

  const SettingsShell({
    super.key,
    required this.title,
    required this.categories,
    this.appBarBottom,
  });

  @override
  State<SettingsShell> createState() => _SettingsShellState();
}

class _SettingsShellState extends State<SettingsShell> {
  static const double _wideBreakpoint = 720;
  static const double _railWidth = 280;

  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return constraints.maxWidth >= _wideBreakpoint
            ? _buildWide(context)
            : _buildNarrow(context);
      },
    );
  }

  PreferredSizeWidget _appBar(String title) {
    return AppBar(
      title: Text(title),
      centerTitle: true,
      bottom: widget.appBarBottom,
    );
  }

  Widget _buildWide(BuildContext context) {
    final categories = widget.categories;
    final selected = _selected.clamp(0, categories.length - 1);
    return Scaffold(
      appBar: _appBar(widget.title),
      body: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: _railWidth,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: categories.length,
                itemBuilder: (context, i) {
                  final category = categories[i];
                  return ListTile(
                    leading: Icon(category.icon),
                    title: Text(category.title),
                    selected: i == selected,
                    selectedTileColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    onTap: () => setState(() => _selected = i),
                  );
                },
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: KeyedSubtree(
                key: ValueKey<int>(selected),
                child: categories[selected].builder(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNarrow(BuildContext context) {
    final categories = widget.categories;
    return Scaffold(
      appBar: _appBar(widget.title),
      body: SafeArea(
        top: false,
        child: ListView.builder(
          itemCount: categories.length,
          itemBuilder: (context, i) {
            final category = categories[i];
            return ListTile(
              leading: Icon(category.icon),
              title: Text(category.title),
              subtitle: category.subtitle != null
                  ? Text(category.subtitle!)
                  : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openDetail(context, category),
            );
          },
        ),
      ),
    );
  }

  void _openDetail(BuildContext context, SettingsCategory category) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(category.title),
            centerTitle: true,
            bottom: widget.appBarBottom,
          ),
          body: SafeArea(top: false, child: category.builder(context)),
        ),
      ),
    );
  }
}
