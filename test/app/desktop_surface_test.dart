import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/app/desktop_surface.dart';

void main() {
  test('keeps a taskbar entry when manual mode has no tray', () {
    expect(
      requiresPersistentDesktopEntry(
        manualClipboardMode: true,
      ),
      isTrue,
    );
    expect(
      requiresPersistentDesktopEntry(manualClipboardMode: false),
      isFalse,
    );
  });

  testWidgets('renders exactly the selected desktop surface', (tester) async {
    Future<void> pump(DesktopSurface surface) => tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: DesktopSurfaceHost(
              surface: surface,
              overlay: const Text('overlay-surface'),
              settings: const Text('settings-surface'),
            ),
          ),
        );

    await pump(DesktopSurface.overlay);
    expect(find.text('overlay-surface'), findsOneWidget);
    expect(find.text('settings-surface'), findsNothing);

    await pump(DesktopSurface.settings);
    expect(find.text('overlay-surface'), findsNothing);
    expect(find.text('settings-surface'), findsOneWidget);
  });
}
