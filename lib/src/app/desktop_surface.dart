import 'package:flutter/widgets.dart';

enum DesktopSurface { overlay, settings }

bool requiresPersistentDesktopEntry({
  required bool manualClipboardMode,
}) =>
    manualClipboardMode;

class DesktopSurfaceHost extends StatelessWidget {
  const DesktopSurfaceHost({
    super.key,
    required this.surface,
    required this.overlay,
    required this.settings,
  });

  final DesktopSurface surface;
  final Widget overlay;
  final Widget settings;

  @override
  Widget build(BuildContext context) => switch (surface) {
        DesktopSurface.overlay => overlay,
        DesktopSurface.settings => settings,
      };
}
