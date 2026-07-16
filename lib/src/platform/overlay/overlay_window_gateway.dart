import 'package:flutter/rendering.dart';

abstract interface class OverlayWindowGateway {
  Future<Size> getScreenSize();

  Future<Rect> getWorkAreaForPoint(Offset point);

  Future<Offset> getCursorPos();

  Future<int> getForegroundWindow();

  void setOriginalForegroundWindow(int handle);

  int getOriginalForegroundWindow();

  Future<int> getFlutterWindowHandle();
}

abstract interface class NativeOverlayPlacementGateway {
  Future<NativeOverlayPlacement> resolveOverlayPlacement({
    required Offset point,
    required Size desiredLogicalSize,
    double logicalGap = 10,
  });

  void applyOverlayPlacement(NativeOverlayPlacement placement);
}

final class NativeOverlayPlacement {
  const NativeOverlayPlacement({
    required this.nativeWindowHandle,
    required this.nativeBounds,
    required this.logicalSize,
  });

  final int nativeWindowHandle;
  final Rect nativeBounds;
  final Size logicalSize;
}

abstract interface class OverlayAnchorGateway {
  Future<Offset?> getCaretAnchorPoint(int targetWindow);
}

Future<Offset> resolveOverlayAnchorPoint(OverlayWindowGateway gateway) async {
  final target = gateway.getOriginalForegroundWindow();
  if (target != 0 && gateway is OverlayAnchorGateway) {
    try {
      final caret =
          await (gateway as OverlayAnchorGateway).getCaretAnchorPoint(target);
      if (caret != null) return caret;
    } catch (_) {}
  }
  return gateway.getCursorPos();
}

abstract interface class OverlayMaterialGateway {
  Future<bool> applyGlassMaterial();
}

abstract interface class NativeOverlayActivationGateway {
  void setWindowCanActivate(int nativeWindowHandle, bool canActivate);

  void showWindowInactive(int nativeWindowHandle);
}

abstract interface class NativeOwnedOverlayActivationGateway {
  Future<void> setOwnedWindowCanActivate(bool canActivate);

  Future<void> showOwnedWindowInactive();
}

Rect nearestWorkArea(Offset point, Iterable<Rect> workAreas) {
  final areas = workAreas.where((area) => !area.isEmpty).toList();
  if (areas.isEmpty) return Rect.zero;
  for (final area in areas) {
    if (area.contains(point)) return area;
  }
  areas.sort((left, right) {
    double distance(Rect area) {
      final dx = point.dx - area.center.dx;
      final dy = point.dy - area.center.dy;
      return (dx * dx) + (dy * dy);
    }

    return distance(left).compareTo(distance(right));
  });
  return areas.first;
}

bool overlayTargetForegroundChanged({
  required int currentForeground,
  required int originalForeground,
  required int flutterWindow,
}) =>
    currentForeground != 0 &&
    currentForeground != originalForeground &&
    currentForeground != flutterWindow;

Future<int?> captureExternalForegroundWindow(
  OverlayWindowGateway gateway,
) async {
  final foreground = await gateway.getForegroundWindow();
  final flutterWindow = await gateway.getFlutterWindowHandle();
  return foreground != 0 && foreground != flutterWindow ? foreground : null;
}
