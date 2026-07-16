import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_gateway.dart';

void main() {
  test('first tray open captures the external foreground before the menu',
      () async {
    final gateway = _FakeOverlayGateway(foreground: 42, flutterWindow: 7);

    expect(await captureExternalForegroundWindow(gateway), 42);
  });

  test('Flutter foreground clears rather than reusing a stale target',
      () async {
    final gateway = _FakeOverlayGateway(foreground: 7, flutterWindow: 7)
      ..setOriginalForegroundWindow(42);

    final captured = await captureExternalForegroundWindow(gateway);
    gateway.setOriginalForegroundWindow(captured ?? 0);

    expect(captured, isNull);
    expect(gateway.publishedTarget, 0);
  });

  test('non-activating overlay keeps the original target foreground', () {
    expect(
      overlayTargetForegroundChanged(
        currentForeground: 42,
        originalForeground: 42,
        flutterWindow: 7,
      ),
      isFalse,
    );
    expect(
      overlayTargetForegroundChanged(
        currentForeground: 7,
        originalForeground: 42,
        flutterWindow: 7,
      ),
      isFalse,
    );
    expect(
      overlayTargetForegroundChanged(
        currentForeground: 99,
        originalForeground: 42,
        flutterWindow: 7,
      ),
      isTrue,
    );
  });
}

final class _FakeOverlayGateway implements OverlayWindowGateway {
  _FakeOverlayGateway({required this.foreground, required this.flutterWindow});

  final int foreground;
  final int flutterWindow;
  int publishedTarget = 0;

  @override
  Future<int> getForegroundWindow() async => foreground;

  @override
  int getOriginalForegroundWindow() => publishedTarget;

  @override
  Future<int> getFlutterWindowHandle() async => flutterWindow;

  @override
  Future<Offset> getCursorPos() async => Offset.zero;

  @override
  Future<Size> getScreenSize() async => Size.zero;

  @override
  Future<Rect> getWorkAreaForPoint(Offset point) async => Rect.zero;

  @override
  void setOriginalForegroundWindow(int handle) => publishedTarget = handle;
}
