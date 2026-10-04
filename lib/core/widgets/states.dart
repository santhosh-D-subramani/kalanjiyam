import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// Centered expressive loading indicator with an optional message.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message, this.detail});

  final String? message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const M3ELoadingIndicator(variant: M3ELoadingIndicatorVariant.contained, size: 72),
            if (message != null) ...<Widget>[
              const SizedBox(height: 20),
              Text(message!, style: text.titleMedium, textAlign: TextAlign.center),
            ],
            if (detail != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                detail!,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Friendly empty / informational state.
class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 96,
                height: 96,
                decoration: ShapeDecoration(
                  color: scheme.secondaryContainer,
                  shape: const StarBorder(points: 8, innerRadiusRatio: 0.82, pointRounding: 0.9),
                ),
                child: Icon(icon, size: 40, color: scheme.onSecondaryContainer),
              ),
              const SizedBox(height: 20),
              Text(title, style: text.titleLarge, textAlign: TextAlign.center),
              if (message != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  message!,
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
              if (action != null) ...<Widget>[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Error state with a retry button.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyView(
      icon: M3EIcons.error_outline,
      title: 'Something went wrong',
      message: message,
      action: onRetry == null
          ? null
          : M3EButton.tonal(onPressed: onRetry, icon: const Icon(M3EIcons.refresh), label: const Text('Try again')),
    );
  }
}

/// Small rounded label used for tags such as "System" or "Needs admin".
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, this.color, this.foreground, this.icon});

  final String label;
  final Color? color;
  final Color? foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fg = foreground ?? scheme.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color ?? scheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[Icon(icon, size: 14, color: fg), const SizedBox(width: 4)],
          Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
        ],
      ),
    );
  }
}

/// A titled group of content on a tonal surface.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, this.subtitle, required this.child, this.trailing});

  final String? title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(24)),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (title != null)
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title!, style: text.titleMedium),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(subtitle!, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          if (title != null) const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}
