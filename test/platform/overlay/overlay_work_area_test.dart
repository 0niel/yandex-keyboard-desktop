import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_gateway.dart';

void main() {
  test('selects the work area containing a global cursor point', () {
    const primary = Rect.fromLTWH(0, 0, 1920, 1040);
    const left = Rect.fromLTWH(-1600, 0, 1600, 860);

    expect(nearestWorkArea(const Offset(-400, 500), [primary, left]), left);
    expect(nearestWorkArea(const Offset(400, 500), [primary, left]), primary);
  });

  test('selects the nearest work area when the cursor is between displays', () {
    const primary = Rect.fromLTWH(0, 0, 1920, 1040);
    const right = Rect.fromLTWH(2200, 0, 1280, 1024);

    expect(nearestWorkArea(const Offset(2100, 500), [primary, right]), right);
  });
}
