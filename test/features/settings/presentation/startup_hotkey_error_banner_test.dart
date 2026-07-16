import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/startup_hotkey_error_banner.dart';

void main() {
  testWidgets('startup hotkey error fits the dedicated error surface',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 220));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        const Stack(
          children: [
            Positioned(
              left: 8,
              right: 8,
              top: 8,
              child: StartupHotKeyErrorBanner(
                rollbackFailed: true,
                onClose: _noop,
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('Shortcut unavailable'), findsOneWidget);
    expect(find.textContaining('no shortcut is active'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup hotkey error delegates dismissal to surface owner',
      (tester) async {
    var dismissed = false;
    await tester.pumpWidget(
      _app(
        StartupHotKeyErrorBanner(
          rollbackFailed: false,
          onClose: () => dismissed = true,
        ),
      ),
    );

    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is AppIconButton && widget.label == 'Dismiss',
      ),
    );
    await tester.pump();

    expect(dismissed, isTrue);
  });
}

Widget _app(Widget child) => AppThemeScope(
      brightness: Brightness.light,
      child: WidgetsApp(
        color: const Color(0xFFFFFFFF),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, __) => builder(context),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ),
        home: child,
      ),
    );

void _noop() {}
