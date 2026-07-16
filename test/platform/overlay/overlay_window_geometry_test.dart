import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_controller.dart';

void main() {
  test('overlay reserves more room in both axes for large text', () {
    expect(
      overlayWindowSizeFor(TextScaler.noScaling),
      const Size(overlayWindowWidth, overlayWindowHeight),
    );
    expect(
      overlayWindowSizeFor(const TextScaler.linear(2)),
      const Size(
        overlayWindowLargeTextWidth,
        overlayWindowLargeTextHeight,
      ),
    );
    expect(
      overlayWindowSizeFor(
        const TextScaler.linear(2),
        manualClipboardMode: true,
      ),
      const Size(
        manualOverlayWindowLargeTextWidth,
        manualOverlayWindowLargeTextHeight,
      ),
    );
  });

  test('every notice expands for large accessibility text', () {
    for (final kind in OverlayNoticeKind.values) {
      final normal = noticeWindowSizeFor(TextScaler.noScaling, kind: kind);
      final large = noticeWindowSizeFor(
        const TextScaler.linear(2),
        kind: kind,
      );
      expect(large.width, greaterThan(normal.width), reason: kind.name);
      expect(large.height, greaterThan(normal.height), reason: kind.name);
    }
    expect(
      noticeWindowSizeFor(
        const TextScaler.linear(3),
        kind: OverlayNoticeKind.recovery,
      ),
      const Size(560, 320),
    );
  });

  test('clamps against a negative-origin secondary monitor work area', () {
    const workArea = Rect.fromLTWH(-1920, 24, 1920, 1056);

    expect(
      clampOverlayPosition(
        desired: const Offset(-100, 1040),
        overlaySize: const Size(456, 72),
        workArea: workArea,
      ),
      const Offset(-456, 1008),
    );
    expect(
      clampOverlayPosition(
        desired: const Offset(-2200, -10),
        overlaySize: const Size(456, 72),
        workArea: workArea,
      ),
      const Offset(-1920, 24),
    );
  });

  test('notice windows fit and center inside a small offset work area', () {
    const workArea = Rect.fromLTWH(-1280, 32, 480, 320);
    const desired = Size(640, 400);

    final fitted = fitWindowSizeToWorkArea(desired, workArea);
    final centered = centerWindowInWorkArea(fitted, workArea);

    expect(fitted, const Size(480, 320));
    expect(centered, const Offset(-1280, 32));
    expect(fitWindowSizeToWorkArea(desired, Rect.zero), desired);
    expect(centerWindowInWorkArea(desired, Rect.zero), Offset.zero);
  });

  test('places the overlay beside the cursor and flips at work-area edges', () {
    const workArea = Rect.fromLTWH(0, 0, 1200, 800);
    const size = Size(420, 82);

    expect(
      positionOverlayNearCursor(
        cursor: const Offset(100, 100),
        overlaySize: size,
        workArea: workArea,
      ),
      const Offset(110, 110),
    );
    expect(
      positionOverlayNearCursor(
        cursor: const Offset(1180, 790),
        overlaySize: size,
        workArea: workArea,
      ),
      const Offset(750, 698),
    );
  });

  test('keeps physical Windows placement coherent at mixed monitor DPI', () {
    expect(
      physicalOverlayBoundsNearPoint(
        point: const Offset(2100, 300),
        physicalWorkArea: const Rect.fromLTWH(1920, 0, 2560, 1440),
        desiredLogicalSize: const Size(420, 60),
        scaleFactor: 2,
      ),
      const Rect.fromLTWH(2120, 320, 840, 120),
    );
    expect(
      physicalOverlayBoundsNearPoint(
        point: const Offset(-20, 1050),
        physicalWorkArea: const Rect.fromLTWH(-1920, 0, 1920, 1080),
        desiredLogicalSize: const Size(420, 60),
        scaleFactor: 1.5,
      ),
      const Rect.fromLTWH(-665, 945, 630, 90),
    );
  });
}
