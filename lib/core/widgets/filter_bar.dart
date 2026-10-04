import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// One selectable filter chip.
class FilterOption<T> {
  const FilterOption({required this.value, required this.label, this.count, this.icon});

  final T value;
  final String label;
  final int? count;
  final IconData? icon;
}

/// Horizontally scrolling row of single-select filter chips.
class FilterChipBar<T> extends StatelessWidget {
  const FilterChipBar({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.trailing = const <Widget>[],
  });

  final List<FilterOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: M3EChipGroup(
        groupLabel: 'Filters',
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: <Widget>[
            for (final FilterOption<T> option in options)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(
                  child: M3EChip(
                    type: M3EChipType.filter,
                    label: option.count == null ? option.label : '${option.label}  ${option.count}',
                    leading: option.icon == null ? null : Icon(option.icon, size: 18),
                    selected: option.value == selected,
                    onPressed: () => onSelected(option.value),
                  ),
                ),
              ),
            ...trailing.map(
              (Widget w) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(child: w),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pill search field used at the top of list pages. Listen to [controller]
/// for changes (the built-in clear button edits the controller directly).
class SearchField extends StatelessWidget {
  const SearchField({super.key, required this.controller, required this.hint, this.trailing});

  final TextEditingController controller;
  final String hint;
  final Iterable<Widget>? trailing;

  @override
  Widget build(BuildContext context) {
    return M3ESearchBar(
      controller: controller,
      hintText: hint,
      leading: const Icon(M3EIcons.search),
      trailing: trailing,
      showClearButton: true,
      expandOnFocus: false,
      margin: 0,
      focusedMargin: 0,
    );
  }
}
