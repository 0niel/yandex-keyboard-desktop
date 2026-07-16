import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app/ios_bootstrap.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/data/file_settings_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/noop_hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/ios/ios_keyboard_settings_gateway.dart';

void main() {
  testWidgets('renders native setup guidance and publishes saved settings',
      (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _MemorySettingsRepository();
    final gateway = _FakeIosKeyboardSettingsGateway();
    final controller = SettingsController(
      repository: repository,
      hotkeyRegistrar: const NoOpHotkeyRegistrar(),
      platform: ShortcutPlatform.ios,
      onShortcutTriggered: (_) {},
      runtimeApplier: IosKeyboardSettingsApplier(gateway),
    );
    addTearDown(controller.close);
    await controller.initialize();
    gateway.writes.clear();

    await tester.pumpWidget(BlocProvider.value(
      value: controller,
      child: IosHostApp(gateway: gateway),
    ));
    expect(find.text('Checking shared keyboard settings…'), findsOneWidget);
    expect(
      find.text('Host and keyboard settings are connected'),
      findsNothing,
    );
    gateway.completeCapabilities();
    await tester.pumpAndSettle();

    expect(find.text('Keyboard Assistant'), findsOneWidget);
    expect(find.text('Set up the keyboard'), findsOneWidget);
    expect(find.textContaining('Full Access'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('Theme'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.scrollUntilVisible(
      find.text('Request timeout'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Request timeout'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('15 s'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CupertinoButton, '15 s'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 s'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('global shortcuts'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('global shortcuts'), findsOneWidget);

    controller.updateGeneral(defaultAction: ShortcutAction.fix);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.widgetWithText(CupertinoButton, 'Save'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(CupertinoButton, 'Save'));
    await tester.pumpAndSettle();

    expect(gateway.writes, hasLength(1));
    expect(gateway.writes.single.defaultAction, ShortcutAction.fix);
    expect(gateway.writes.single.requestTimeoutMilliseconds, 30000);
    expect(repository.value.defaultAction, ShortcutAction.fix);
    expect(repository.value.requestTimeoutMilliseconds, 30000);
  });

  testWidgets('compact pseudo locale is safe with large text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _MemorySettingsRepository();
    final gateway = _FakeIosKeyboardSettingsGateway();
    gateway.completeCapabilities();
    final controller = SettingsController(
      repository: repository,
      hotkeyRegistrar: const NoOpHotkeyRegistrar(),
      platform: ShortcutPlatform.ios,
      onShortcutTriggered: (_) {},
      runtimeApplier: IosKeyboardSettingsApplier(gateway),
    );
    addTearDown(controller.close);
    await controller.initialize();

    await tester.pumpWidget(BlocProvider.value(
      value: controller,
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en', 'XA'),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.5),
            ),
            child: IosKeyboardSettingsPage(gateway: gateway),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.fling(
      find.byType(ListView),
      const Offset(0, -2400),
      1200,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(IosKeyboardSettingsPage), findsOneWidget);
  });
}

final class _MemorySettingsRepository implements SettingsRepository {
  AppSettings value = AppSettings.defaults();

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
}

final class _FakeIosKeyboardSettingsGateway
    implements IosKeyboardSettingsGateway {
  final List<AppSettings> writes = [];
  final Completer<Map<String, Object?>> _capabilities = Completer();

  void completeCapabilities() {
    if (!_capabilities.isCompleted) {
      _capabilities.complete({
        'appGroupAvailable': true,
        'globalShortcuts': false,
        'selectionViaDocumentProxy': true,
        'clipboardMutation': false,
      });
    }
  }

  @override
  Future<Map<String, Object?>> capabilities() => _capabilities.future;

  @override
  Future<Map<String, Object?>> read() async => const {};

  @override
  Future<void> write(AppSettings settings) async => writes.add(settings);
}
