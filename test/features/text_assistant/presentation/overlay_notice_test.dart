import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/text_assistant_overlay.dart';

void main() {
  test('only safe snapshot-capture failures offer the manual workflow', () {
    expect(
      requiresManualClipboardFallback(
        'windows_clipboard_snapshot_format_unsupported',
      ),
      isTrue,
    );
    expect(
      requiresManualClipboardFallback('windows_clipboard_snapshot_too_large'),
      isTrue,
    );
    expect(
      requiresManualClipboardFallback(
        'clipboard_recovery_manual_action_required',
      ),
      isFalse,
    );
    expect(requiresManualClipboardFallback(null), isFalse);
    expect(
      requiresClipboardStateReview(
        'windows_clipboard_snapshot_rollback_failed',
      ),
      isTrue,
    );
    expect(
      requiresClipboardStateReview(
        'windows_clipboard_snapshot_capture_timeout',
      ),
      isFalse,
    );
  });

  testWidgets('notice is a live region and focuses its recovery action',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        OverlayNotice(
          icon: LucideIcons.triangleAlert,
          title: 'Clipboard recovery needed',
          description: 'The target changed.',
          primaryLabel: 'Retry',
          onPrimary: () {},
          secondaryLabel: 'Dismiss',
          onSecondary: () {},
        ),
      ),
    );
    await tester.pump();

    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('overlay-notice-semantics')),
    );
    expect(
      semantics.getSemanticsData().flagsCollection.isLiveRegion,
      isTrue,
    );
    expect(
      semantics.getSemanticsData().hint,
      'Press the Show assistant shortcut again to use the primary action or '
      'dismiss this message.',
    );
    expect(find.bySemanticsLabel('Clipboard recovery needed'), findsNothing);
    expect(find.bySemanticsLabel('The target changed.'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(
      tester
          .widget<AppButton>(
            find.widgetWithText(AppButton, 'Retry'),
          )
          .autofocus,
      isTrue,
    );
  });

  testWidgets('long recovery instructions remain visible at 200 percent',
      (tester) async {
    const description = '[ Thë clïpböärd cöüld nöt bë rëstörëd äütömätïcällÿ. '
        'Rëvïëw thë cürrënt clïpböärd änd rëtrÿ thë säfë rëcövërÿ '
        'wïthöüt övërwrïtïng nëwër ëxtërnäl dätä. ]';
    await tester.binding.setSurfaceSize(const Size(640, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
            ),
            child: OverlayNotice(
              icon: LucideIcons.triangleAlert,
              title: '[ Clïpböärd rëcövërÿ nëëdëd ]',
              description: description,
              primaryLabel: '[ Rëtrÿ rëcövërÿ ]',
              onPrimary: () {},
              secondaryLabel: '[ Dïsmïss ]',
              onSecondary: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(description), findsOneWidget);
    final text = tester.widget<Text>(find.text(description));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNull);
  });

  testWidgets('glass tint is translucent and high contrast is opaque',
      (tester) async {
    Widget notice() => OverlayNotice(
          icon: LucideIcons.info,
          title: 'Check the replacement',
          secondaryLabel: 'Dismiss',
          onSecondary: () {},
        );

    await tester.pumpWidget(_testApp(notice()));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            switch ((widget.decoration as BoxDecoration).gradient) {
              final LinearGradient gradient =>
                gradient.colors.every((color) => color.a < 1),
              _ => false,
            },
      ),
      findsWidgets,
    );

    await tester.pumpWidget(_testApp(notice(), highContrast: true));
    final context = tester.element(find.byType(OverlayNotice));
    final fallback = AppColors.overlayFallback(context);
    expect(fallback.a, 1);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).color == fallback,
      ),
      findsOneWidget,
    );
  });
}

Widget _testApp(Widget home, {bool highContrast = false}) => AppThemeScope(
      brightness: Brightness.light,
      child: WidgetsApp(
        color: AppColors.brand,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, __) => builder(context),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              highContrast: highContrast,
            ),
            child: home,
          ),
        ),
      ),
    );
