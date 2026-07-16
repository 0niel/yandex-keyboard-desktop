import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

const double overlayWindowWidth = 384;
const double overlayWindowHeight = 44;
const double overlayWindowLargeTextWidth = 500;
const double overlayWindowLargeTextHeight = 92;
const double manualOverlayWindowWidth = 440;
const double manualOverlayWindowHeight = 96;
const double manualOverlayWindowLargeTextWidth = 540;
const double manualOverlayWindowLargeTextHeight = 150;

enum OverlayNoticeKind {
  loading,
  success,
  recovery,
  clipboardFallback,
  clipboardStateReview,
  processingLimit,
  failure,
  warning,
  manualPaste,
}

Size noticeWindowSizeFor(
  TextScaler textScaler, {
  required OverlayNoticeKind kind,
}) {
  final scale = textScaler.scale(1).clamp(1.0, 2.0);
  final expansion = scale - 1;
  final (baseWidth, baseHeight, largeWidth, largeHeight) = switch (kind) {
    OverlayNoticeKind.loading => (220.0, 44.0, 300.0, 72.0),
    OverlayNoticeKind.success => (220.0, 44.0, 300.0, 72.0),
    OverlayNoticeKind.recovery => (480.0, 176.0, 560.0, 320.0),
    OverlayNoticeKind.clipboardFallback => (480.0, 176.0, 560.0, 320.0),
    OverlayNoticeKind.clipboardStateReview => (480.0, 176.0, 560.0, 320.0),
    OverlayNoticeKind.processingLimit => (460.0, 132.0, 540.0, 240.0),
    OverlayNoticeKind.failure => (420.0, 60.0, 500.0, 112.0),
    OverlayNoticeKind.warning => (460.0, 132.0, 540.0, 240.0),
    OverlayNoticeKind.manualPaste => (440.0, 144.0, 540.0, 260.0),
  };
  return Size(
    baseWidth + ((largeWidth - baseWidth) * expansion),
    baseHeight + ((largeHeight - baseHeight) * expansion),
  );
}

Size fitWindowSizeToWorkArea(Size desired, Rect workArea) {
  if (workArea.isEmpty) return desired;
  return Size(
    desired.width.clamp(1, workArea.width),
    desired.height.clamp(1, workArea.height),
  );
}

Rect physicalOverlayBoundsNearPoint({
  required Offset point,
  required Rect physicalWorkArea,
  required Size desiredLogicalSize,
  required double scaleFactor,
  double logicalGap = 10,
}) {
  final safeScale = scaleFactor > 0 ? scaleFactor : 1.0;
  final desiredPhysicalSize = Size(
    desiredLogicalSize.width * safeScale,
    desiredLogicalSize.height * safeScale,
  );
  final fittedPhysicalSize = fitWindowSizeToWorkArea(
    desiredPhysicalSize,
    physicalWorkArea,
  );
  final position = positionOverlayNearCursor(
    cursor: point,
    overlaySize: fittedPhysicalSize,
    workArea: physicalWorkArea,
    gap: logicalGap * safeScale,
  );
  return position & fittedPhysicalSize;
}

Offset centerWindowInWorkArea(Size windowSize, Rect workArea) {
  if (workArea.isEmpty) return Offset.zero;
  return Offset(
    workArea.left + ((workArea.width - windowSize.width) / 2),
    workArea.top + ((workArea.height - windowSize.height) / 2),
  );
}

Size overlayWindowSizeFor(
  TextScaler textScaler, {
  bool manualClipboardMode = false,
}) {
  final usesLargeTextLayout = textScaler.scale(1) > 1.3;
  return Size(
    usesLargeTextLayout
        ? (manualClipboardMode
            ? manualOverlayWindowLargeTextWidth
            : overlayWindowLargeTextWidth)
        : (manualClipboardMode ? manualOverlayWindowWidth : overlayWindowWidth),
    usesLargeTextLayout
        ? (manualClipboardMode
            ? manualOverlayWindowLargeTextHeight
            : overlayWindowLargeTextHeight)
        : (manualClipboardMode
            ? manualOverlayWindowHeight
            : overlayWindowHeight),
  );
}

Offset clampOverlayPosition({
  required Offset desired,
  required Size overlaySize,
  required Rect workArea,
}) {
  if (workArea.isEmpty) return desired;
  final maximumLeft = (workArea.right - overlaySize.width)
      .clamp(workArea.left, double.infinity);
  final maximumTop = (workArea.bottom - overlaySize.height)
      .clamp(workArea.top, double.infinity);
  return Offset(
    desired.dx.clamp(workArea.left, maximumLeft),
    desired.dy.clamp(workArea.top, maximumTop),
  );
}

Offset positionOverlayNearCursor({
  required Offset cursor,
  required Size overlaySize,
  required Rect workArea,
  double gap = 10,
}) {
  var left = cursor.dx + gap;
  var top = cursor.dy + gap;
  if (!workArea.isEmpty) {
    if (left + overlaySize.width > workArea.right) {
      left = cursor.dx - overlaySize.width - gap;
    }
    if (top + overlaySize.height > workArea.bottom) {
      top = cursor.dy - overlaySize.height - gap;
    }
  }
  return clampOverlayPosition(
    desired: Offset(left, top),
    overlaySize: overlaySize,
    workArea: workArea,
  );
}

class OverlayWindowController {
  static Future<void> initialize({
    Size size = const Size(overlayWindowWidth, overlayWindowHeight),
  }) async {
    await windowManager.setBackgroundColor(const Color(0x00000000));
    if (!_usesNativeWaylandDecorations) {
      await windowManager.setAsFrameless();
    }
    if (Platform.isWindows) {
      await windowManager.setHasShadow(false);
    }
    await windowManager.setMinimumSize(size);
    await windowManager.setSize(size);
    await windowManager.setAlwaysOnTop(true);
  }

  static bool get _usesNativeWaylandDecorations =>
      Platform.isLinux &&
      Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty == true &&
      Platform.environment['GDK_BACKEND'] != 'x11';
}
