import 'dart:io';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// Renders an icon file (SVG/PNG) with a graceful fallback.
class FileIcon extends StatelessWidget {
  const FileIcon({super.key, required this.path, this.size = 40, this.fallback = M3EIcons.apps});

  final String? path;
  final double size;
  final IconData fallback;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(size * 0.3)),
      child: Icon(fallback, size: size * 0.55, color: scheme.onSecondaryContainer),
    );
    final String? p = path;
    if (p == null) return placeholder;
    final String lower = p.toLowerCase();
    if (lower.endsWith('.svg') || lower.endsWith('.svgz')) {
      if (lower.endsWith('.svgz')) return placeholder;
      return SizedBox(
        width: size,
        height: size,
        child: SvgPicture.file(
          File(p),
          width: size,
          height: size,
          placeholderBuilder: (_) => placeholder,
          errorBuilder: (BuildContext context, Object error, StackTrace stackTrace) => placeholder,
        ),
      );
    }
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp')) {
      return Image.file(
        File(p),
        width: size,
        height: size,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        filterQuality: FilterQuality.medium,
        errorBuilder: (BuildContext context, Object error, StackTrace? stackTrace) => placeholder,
      );
    }
    // XPM and other legacy formats are not supported by Flutter.
    return placeholder;
  }
}
