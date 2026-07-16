import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_gateway.dart';

void main() {
  const caret = Offset(120, 340);
  const cursor = Offset(2800, 90);

  test('prefers the target caret over the mouse cursor', () async {
    final gateway = _FakeAnchorGateway(caret: caret, cursor: cursor)
      ..setOriginalForegroundWindow(42);

    expect(await resolveOverlayAnchorPoint(gateway), caret);
    expect(gateway.requestedCaretTarget, 42);
  });

  test('falls back to the cursor when no caret is available', () async {
    final gateway = _FakeAnchorGateway(caret: null, cursor: cursor)
      ..setOriginalForegroundWindow(42);

    expect(await resolveOverlayAnchorPoint(gateway), cursor);
  });

  test('falls back to the cursor when no target was captured', () async {
    final gateway = _FakeAnchorGateway(caret: caret, cursor: cursor);

    expect(await resolveOverlayAnchorPoint(gateway), cursor);
    expect(gateway.requestedCaretTarget, isNull);
  });

  test('falls back to the cursor when the anchor probe throws', () async {
    final gateway = _FakeAnchorGateway(
      caret: caret,
      cursor: cursor,
      caretError: StateError('probe failed'),
    )..setOriginalForegroundWindow(42);

    expect(await resolveOverlayAnchorPoint(gateway), cursor);
  });

  test('uses the cursor when the platform has no anchor capability', () async {
    final gateway = _FakeCursorOnlyGateway(cursor: cursor)
      ..setOriginalForegroundWindow(42);

    expect(await resolveOverlayAnchorPoint(gateway), cursor);
  });
}

final class _FakeCursorOnlyGateway implements OverlayWindowGateway {
  _FakeCursorOnlyGateway({required this.cursor});

  final Offset cursor;
  int _target = 0;

  @override
  Future<Offset> getCursorPos() async => cursor;

  @override
  Future<int> getForegroundWindow() async => 0;

  @override
  Future<int> getFlutterWindowHandle() async => 0;

  @override
  int getOriginalForegroundWindow() => _target;

  @override
  Future<Size> getScreenSize() async => Size.zero;

  @override
  Future<Rect> getWorkAreaForPoint(Offset point) async => Rect.zero;

  @override
  void setOriginalForegroundWindow(int handle) => _target = handle;
}

final class _FakeAnchorGateway extends _FakeCursorOnlyGateway
    implements OverlayAnchorGateway {
  _FakeAnchorGateway({
    required this.caret,
    required super.cursor,
    this.caretError,
  });

  final Offset? caret;
  final Object? caretError;
  int? requestedCaretTarget;

  @override
  Future<Offset?> getCaretAnchorPoint(int targetWindow) async {
    requestedCaretTarget = targetWindow;
    final error = caretError;
    if (error != null) throw error;
    return caret;
  }
}
