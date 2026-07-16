import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/application/privacy_activity_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/data/file_settings_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/settings_window.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_operation_gate.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_state.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_processing_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/text_assistant_overlay.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/manual_clipboard_selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/platform_selection_backend.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('manual copy transform paste workflow crosses the real UI stack',
      (tester) async {
    final clipboard = _MemoryClipboard('Hello integration');
    final settingsController = _settingsController(_MemorySettingsRepository());
    final textController = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(clipboard: clipboard),
      processingRepository: const _UppercaseRepository(),
      policyProvider: const FixedTextAssistantRuntimePolicyProvider(),
    );
    await settingsController.initialize();
    addTearDown(() async {
      await settingsController.close();
      await textController.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('window_manager'), null);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => switch (call.method) {
        'getBounds' => <String, double>{
            'x': 0,
            'y': 0,
            'width': 540,
            'height': 176,
          },
        'isVisible' || 'isFocused' => true,
        'isMinimized' => false,
        _ => null,
      },
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          BlocProvider.value(value: settingsController),
          BlocProvider.value(value: textController),
          Provider<OverlayWindowGateway>.value(value: const _OverlayGateway()),
          Provider<TextOperationGate>.value(value: TextOperationGate()),
        ],
        child: _app(const TextAssistantOverlay()),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Copy the selected text first'), findsOneWidget);
    final terminal = textController.stream.firstWhere(
      (state) => state.stage == TextReplacementStage.awaitingManualPaste,
    );
    await tester.tap(find.text('Improve'));
    await terminal;
    await tester.pumpAndSettle();

    expect(find.text('Ready to paste'), findsOneWidget);
    expect(clipboard.value, 'HELLO INTEGRATION');
  });

  testWidgets('keybinding edit is saved through presentation and controller',
      (tester) async {
    final repository = _MemorySettingsRepository();
    final settingsController = _settingsController(repository);
    final privacyController = PrivacyActivityController(
      repository: _MemoryPrivacyRepository(),
    );
    await settingsController.initialize();
    await privacyController.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 820));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await settingsController.close();
      await privacyController.close();
    });

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: settingsController),
          BlocProvider.value(value: privacyController),
        ],
        child: _app(SettingsWindow(onSaved: () {})),
      ),
    );
    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ctrl + Alt + Space'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('Ctrl + A'), findsOneWidget);
    await tester.tap(
      find.widgetWithText(AppButton, 'Apply'),
    );
    await tester.pumpAndSettle();
    expect(
      settingsController.state.draft!.activeProfile
          .bindings[ShortcutAction.showOverlay]!.signature,
      'control+A',
    );
    final saveButton = find.widgetWithText(AppButton, 'Save');
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(
      repository
          .value.activeProfile.bindings[ShortcutAction.showOverlay]!.signature,
      'control+A',
    );
  });
}

Widget _app(Widget home) => AppThemeScope(
      brightness: Brightness.light,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: home,
      ),
    );

SettingsController _settingsController(_MemorySettingsRepository repository) =>
    SettingsController(
      repository: repository,
      hotkeyRegistrar: const _NoOpRegistrar(),
      platform: ShortcutPlatform.windows,
      onShortcutTriggered: (_) {},
    );

final class _MemorySettingsRepository implements SettingsRepository {
  _MemorySettingsRepository() : value = AppSettings.defaults();

  AppSettings value;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
}

final class _NoOpRegistrar implements HotkeyRegistrar {
  const _NoOpRegistrar();

  @override
  Future<void> replaceProfile({
    required KeyBindingProfile previous,
    required KeyBindingProfile next,
    required void Function(ShortcutAction action) onTriggered,
  }) async {}

  @override
  Future<void> unregisterAll() async {}
}

final class _MemoryClipboard implements ClipboardTextGateway {
  _MemoryClipboard(this.value);

  String value;

  @override
  Future<String> readText() async => value;

  @override
  Future<void> writeText(String text) async => value = text;
}

final class _UppercaseRepository implements TextProcessingRepository {
  const _UppercaseRepository();

  @override
  Future<String> process({
    required String text,
    required TextAction action,
    TextAssistantRuntimePolicy? policy,
    TextProcessingCancellationToken? cancellationToken,
  }) async =>
      text.toUpperCase();
}

final class _MemoryPrivacyRepository implements PrivacyActivityRepository {
  PrivacyActivitySnapshot value = PrivacyActivitySnapshot.empty();

  @override
  Future<PrivacyActivitySnapshot> load() async => value;

  @override
  Future<PrivacyActivitySnapshot> record(
    PrivacyActivityEvent event, {
    required PrivacyConsent consent,
  }) async =>
      value;

  @override
  Future<PrivacyActivitySnapshot> clearHistory() async => value;

  @override
  Future<PrivacyActivitySnapshot> clearDiagnostics() async => value;

  @override
  Future<String> exportDiagnostics() async => 'safe-export.json';
}

final class _OverlayGateway implements OverlayWindowGateway {
  const _OverlayGateway();

  @override
  Future<Offset> getCursorPos() async => Offset.zero;

  @override
  Future<int> getFlutterWindowHandle() async => 1;

  @override
  Future<int> getForegroundWindow() async => 2;

  @override
  int getOriginalForegroundWindow() => 2;

  @override
  Future<Size> getScreenSize() async => const Size(1920, 1080);

  @override
  Future<Rect> getWorkAreaForPoint(Offset point) async =>
      const Rect.fromLTWH(0, 0, 1920, 1040);

  @override
  void setOriginalForegroundWindow(int handle) {}
}
