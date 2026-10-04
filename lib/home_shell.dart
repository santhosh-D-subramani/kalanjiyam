import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'features/desktop_entries/desktop_entries_page.dart';
import 'features/packages/packages_page.dart';
import 'features/settings/settings_page.dart';
import 'features/storage/storage_page.dart';

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const List<_Destination> _destinations = <_Destination>[
  _Destination('Packages', M3EIcons.inventory_2_outlined, M3EIcons.inventory_2),
  _Destination('Launchers', M3EIcons.apps_outlined, M3EIcons.apps),
  _Destination('Storage', M3EIcons.pie_chart_outline, M3EIcons.pie_chart),
  _Destination('Settings', M3EIcons.settings_outlined, M3EIcons.settings),
];

/// Adaptive navigation: a navigation rail on wide windows, a navigation bar
/// on narrow ones. Pages are created lazily and kept alive afterwards so
/// switching tabs never repeats a scan.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialPage});

  final String? initialPage;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _index = switch (widget.initialPage?.toLowerCase()) {
    'launchers' || 'desktop-entries' => 1,
    'storage' => 2,
    'settings' => 3,
    _ => 0,
  };
  late final Set<int> _visited = <int>{_index};

  Widget _page(int index) => switch (index) {
    0 => const PackagesPage(),
    1 => const DesktopEntriesPage(),
    2 => const StoragePage(),
    _ => const SettingsPage(),
  };

  void _select(int index) {
    setState(() {
      _index = index;
      _visited.add(index);
    });
  }

  Widget _body() {
    return IndexedStack(
      index: _index,
      children: <Widget>[
        for (int i = 0; i < _destinations.length; i++) _visited.contains(i) ? _page(i) : const SizedBox.shrink(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < 720) {
          return Scaffold(
            backgroundColor: scheme.surface,
            body: _body(),
            bottomNavigationBar: M3ENavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _select,
              destinations: <M3ENavigationBarDestination>[
                for (final _Destination d in _destinations)
                  M3ENavigationBarDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selectedIcon), label: d.label),
              ],
            ),
          );
        }
        final M3ENavigationRailType type = constraints.maxWidth >= 1280
            ? M3ENavigationRailType.expanded
            : M3ENavigationRailType.collapsed;
        return Scaffold(
          backgroundColor: scheme.surface,
          body: Row(
            children: <Widget>[
              M3ENavigationRail(
                key: ValueKey<M3ENavigationRailType>(type),
                type: type,
                selectedIndex: _index,
                onDestinationSelected: _select,
                leading: const _AppMark(),
                sections: <M3ENavigationRailSection>[
                  M3ENavigationRailSection(
                    destinations: <M3ENavigationRailDestination>[
                      for (final _Destination d in _destinations)
                        M3ENavigationRailDestination(
                          icon: Icon(d.icon),
                          selectedIcon: Icon(d.selectedIcon),
                          label: d.label,
                        ),
                    ],
                  ),
                ],
              ),
              Expanded(child: _body()),
            ],
          ),
        );
      },
    );
  }
}

/// The app's mark: the Tamil letter "க" (the first letter of களஞ்சியம்) on
/// an expressive cookie shape.
class _AppMark extends StatelessWidget {
  const _AppMark();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$kAppName · $kAppTamilName',
      child: SvgPicture.asset('assets/logo/kalanjiyam.svg', width: 48, height: 48),
    );
  }
}
