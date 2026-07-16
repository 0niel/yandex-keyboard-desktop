import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/data/file_settings_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/text_action_bar.dart';

void main() {
  testWidgets('puts the saved default action first without restarting',
      (tester) async {
    final repository = _MemorySettingsRepository(
      AppSettings.defaults().copyWith(defaultAction: ShortcutAction.fix),
    );
    final controller = SettingsController(
      repository: repository,
      hotkeyRegistrar: _NoOpRegistrar(),
      platform: ShortcutPlatform.windows,
      onShortcutTriggered: (_) {},
    );
    await controller.initialize();
    addTearDown(controller.close);

    await tester.pumpWidget(_app(controller));
    expect(
      tester.getTopLeft(find.text('Fix errors')).dx,
      lessThan(tester.getTopLeft(find.text('Improve')).dx),
    );

    controller.updateGeneral(defaultAction: ShortcutAction.emojify);
    expect(await controller.save(), isTrue);
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('Emojify')).dx,
      lessThan(tester.getTopLeft(find.text('Fix errors')).dx),
    );
  });

  testWidgets('pseudo locale remains layout-safe at 200 percent text scale',
      (tester) async {
    final controller = SettingsController(
      repository: _MemorySettingsRepository(AppSettings.defaults()),
      hotkeyRegistrar: _NoOpRegistrar(),
      platform: ShortcutPlatform.windows,
      onShortcutTriggered: (_) {},
    );
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(456, 104));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(
      _app(
        controller,
        locale: const Locale('en', 'XA'),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(TextActionBar), findsOneWidget);
  });

  testWidgets('manual clipboard mode discloses the read and replace behavior',
      (tester) async {
    final controller = SettingsController(
      repository: _MemorySettingsRepository(AppSettings.defaults()),
      hotkeyRegistrar: _NoOpRegistrar(),
      platform: ShortcutPlatform.linux,
      onShortcutTriggered: (_) {},
    );
    await controller.initialize();
    addTearDown(controller.close);

    await tester.pumpWidget(_app(controller, manualClipboardMode: true));

    expect(
      find.textContaining('Copy the selected text first'),
      findsOneWidget,
    );
    expect(find.text('Improve'), findsOneWidget);
  });

  testWidgets('keeps all three action slots aligned to equal widths',
      (tester) async {
    final controller = SettingsController(
      repository: _MemorySettingsRepository(AppSettings.defaults()),
      hotkeyRegistrar: _NoOpRegistrar(),
      platform: ShortcutPlatform.windows,
      onShortcutTriggered: (_) {},
    );
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(420, 52));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(_app(controller));

    final widths = ['Improve', 'Emojify', 'Fix errors']
        .map((label) =>
            tester.getSize(find.widgetWithText(AppButton, label)).width)
        .toList();
    expect(widths[0], closeTo(widths[1], 0.01));
    expect(widths[1], closeTo(widths[2], 0.01));
  });
}

Widget _app(
  SettingsController controller, {
  Locale locale = const Locale('en'),
  TextScaler textScaler = TextScaler.noScaling,
  bool manualClipboardMode = false,
}) =>
    BlocProvider.value(
      value: controller,
      child: AppThemeScope(
        brightness: Brightness.light,
        child: WidgetsApp(
          color: AppColors.brand,
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
            settings: settings,
            pageBuilder: (context, _, __) => builder(context),
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: TextActionBar(
                manualClipboardMode: manualClipboardMode,
                processClipboardText: (_, __) async {},
              ),
            ),
          ),
        ),
      ),
    );

final class _MemorySettingsRepository implements SettingsRepository {
  _MemorySettingsRepository(this.value);

  AppSettings value;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
}

final class _NoOpRegistrar implements HotkeyRegistrar {
  @override
  Future<void> replaceProfile({
    required KeyBindingProfile previous,
    required KeyBindingProfile next,
    required void Function(ShortcutAction action) onTriggered,
  }) async {}

  @override
  Future<void> unregisterAll() async {}
}
