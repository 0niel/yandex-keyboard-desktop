import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/settings_window.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/settings_widgets.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/application/privacy_activity_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/data/file_settings_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_runtime_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

void main() {
  testWidgets('shows every configurable action in shortcut settings',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 820));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();
    expect(find.text('SHOW ASSISTANT'), findsOneWidget);
    expect(find.text('EMOJIFY SELECTED TEXT'), findsOneWidget);
    expect(find.text('IMPROVE SELECTED TEXT'), findsOneWidget);
    expect(find.text('FIX ERRORS IN SELECTED TEXT'), findsOneWidget);
    expect(find.text('Ctrl + Alt + Space'), findsOneWidget);
  });

  testWidgets('records a supported chord without null assertions',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 820));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ctrl + Alt + Space'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(find.text('Ctrl + A'), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(
      controller.state.draft!.activeProfile
          .bindings[ShortcutAction.showOverlay]!.signature,
      'control+A',
    );
  });

  testWidgets('profile dialogs cover create duplicate rename import and export',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    String? copiedProfile;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedProfile =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();
    Future<void> openMore() async {
      final more = _iconButton('More');
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('New profile'));
    await tester.pumpAndSettle();
    await tester.enterText(_editableText(), '  Work  ');
    await tester.tap(_button('Apply'));
    await tester.pumpAndSettle();
    expect(controller.state.draft!.activeProfile.name, 'Work');
    expect(controller.state.draft!.profiles, hasLength(2));

    await openMore();
    await tester.tap(find.text('Duplicate profile'));
    await tester.pumpAndSettle();
    await tester.enterText(_editableText(), 'Work copy');
    await tester.tap(_button('Apply'));
    await tester.pumpAndSettle();
    expect(controller.state.draft!.activeProfile.name, 'Work copy');
    expect(controller.state.draft!.profiles, hasLength(3));

    await openMore();
    await tester.tap(find.text('Rename profile'));
    await tester.pumpAndSettle();
    await tester.enterText(_editableText(), 'Renamed');
    await tester.tap(_button('Apply'));
    await tester.pumpAndSettle();
    expect(controller.state.draft!.activeProfile.name, 'Renamed');

    final exported = controller.exportActiveProfile();
    await openMore();
    await tester.tap(find.text('Import profile'));
    await tester.pumpAndSettle();
    await tester.enterText(_editableText(), '{ invalid');
    await tester.tap(_button('Import profile'));
    await tester.pumpAndSettle();
    expect(
      find.text('This shortcut profile is invalid or unsafe.'),
      findsOneWidget,
    );
    await tester.enterText(_editableText(), exported);
    await tester.tap(_button('Import profile'));
    await tester.pumpAndSettle();
    expect(controller.state.draft!.profiles, hasLength(4));

    await openMore();
    await tester.tap(find.text('Export profile'));
    await tester.pumpAndSettle();
    final exportBox = tester.widget<AppTextField>(find.byType(AppTextField));
    expect(exportBox.readOnly, isTrue);
    await tester.tap(
      _button('Copy to clipboard'),
    );
    await tester.pumpAndSettle();
    expect(copiedProfile, contains('yandex-keyboard-keybinding-profile'));

    controller.updateBinding(
      ShortcutAction.showOverlay,
      KeyChord(key: 'Q', modifiers: const {KeyModifier.control}),
    );
    await tester.pump();
    await openMore();
    await tester.tap(find.text('Reset profile'));
    await tester.pumpAndSettle();
    expect(
      controller.state.draft!.activeProfile
          .bindings[ShortcutAction.showOverlay]!.signature,
      KeyBindingProfile.defaults()
          .bindings[ShortcutAction.showOverlay]!
          .signature,
    );

    final beforeDelete = controller.state.draft!.profiles.length;
    await openMore();
    await tester.tap(find.text('Delete profile'));
    await tester.pumpAndSettle();
    expect(controller.state.draft!.profiles, hasLength(beforeDelete - 1));
  });

  testWidgets('keybinding dialogs satisfy the raw route semantics contract',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 820));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();
    await tester.tap(_button('New profile'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final routeSemantics = tester.widget<Semantics>(
      find.descendant(
        of: find.byType(AppDialog),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.scopesRoute == true,
        ),
      ),
    );
    expect(routeSemantics.properties.namesRoute, isTrue);
    expect(routeSemantics.explicitChildNodes, isTrue);
  });

  testWidgets('represents the full persisted timeout and retry ranges',
      (tester) async {
    final controller = _controller(
      AppSettings.defaults().copyWith(
        requestTimeoutMilliseconds: 120000,
        retryAttempts: 8,
      ),
    );
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 820));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(_app(controller));

    final integerControls =
        tester.widgetList<AppSelect<int>>(find.byType(AppSelect<int>)).toList();
    expect(
      integerControls
          .singleWhere((control) => control.items.containsKey(120000))
          .value,
      120000,
    );
    expect(
      integerControls
          .singleWhere((control) => control.items.containsKey(8))
          .value,
      8,
    );
  });

  testWidgets('general controls update, discard, and save the complete draft',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    var saved = 0;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(_app(controller, onSaved: () => saved++));

    tester
        .widget<AppSelect<AppThemePreference>>(
          find.byType(AppSelect<AppThemePreference>),
        )
        .onChanged(AppThemePreference.dark);
    tester
        .widget<AppSelect<String>>(
          find.byType(AppSelect<String>).first,
        )
        .onChanged('ru');
    tester
        .widget<AppSwitch>(
          _switch('Launch at startup'),
        )
        .onChanged(true);
    tester
        .widget<AppSelect<ShortcutAction>>(
          find.byType(AppSelect<ShortcutAction>),
        )
        .onChanged(ShortcutAction.fix);
    final integerControls =
        tester.widgetList<AppSelect<int>>(find.byType(AppSelect<int>)).toList();
    integerControls
        .singleWhere((control) => control.items.containsKey(120000))
        .onChanged(30000);
    integerControls
        .singleWhere((control) => control.items.containsKey(8))
        .onChanged(5);
    await tester.pump();

    expect(controller.state.draft!.theme, AppThemePreference.dark);
    expect(controller.state.draft!.locale, 'ru');
    expect(controller.state.draft!.launchAtStartup, isTrue);
    expect(controller.state.draft!.defaultAction, ShortcutAction.fix);
    expect(controller.state.draft!.requestTimeoutMilliseconds, 30000);
    expect(controller.state.draft!.retryAttempts, 5);

    await tester.tap(_button('Discard'));
    await tester.pump();
    expect(controller.state.isDirty, isFalse);

    tester
        .widget<AppSwitch>(
          _switch('Launch at startup'),
        )
        .onChanged(true);
    await tester.pump();
    await tester.tap(_button('Save'));
    await tester.pumpAndSettle();
    expect(saved, 1);
    expect(controller.state.isDirty, isFalse);
  });

  testWidgets('close confirms dirty drafts and honors both window policies',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    var hidden = 0;
    var minimized = 0;
    var closed = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        if (call.method == 'hide') hidden++;
        if (call.method == 'minimize') minimized++;
        return null;
      },
    );
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('window_manager'), null);
      await controller.close();
    });

    await tester.pumpWidget(
      _app(
        controller,
        minimizeOnClose: true,
        onClosed: () => closed++,
      ),
    );
    controller.updateGeneral(launchAtStartup: true);
    await tester.pump();
    expect(controller.state.isDirty, isTrue);
    tester
        .widget<AppIconButton>(
          _iconButton('Dismiss'),
        )
        .onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await tester.tap(_dialogButton('Cancel'));
    await tester.pumpAndSettle();
    expect(minimized, 0);

    tester
        .widget<AppIconButton>(
          _iconButton('Dismiss'),
        )
        .onPressed!();
    await tester.pumpAndSettle();
    await tester.tap(_dialogButton('Discard'));
    await tester.pumpAndSettle();
    expect(minimized, 1);
    expect(closed, 1);
    expect(controller.state.isDirty, isFalse);

    await tester.pumpWidget(_app(controller));
    tester
        .widget<AppIconButton>(
          _iconButton('Dismiss'),
        )
        .onPressed!();
    await tester.pumpAndSettle();
    expect(hidden, 1);
  });

  testWidgets('privacy settings expose opt-in metadata, clear, and export',
      (tester) async {
    final controller = _controller();
    final privacyRepository = _MemoryPrivacyRepository();
    final privacyController =
        PrivacyActivityController(repository: privacyRepository);
    await controller.initialize();
    await privacyController.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
      await privacyController.close();
    });

    await tester.pumpWidget(
      _app(controller, privacyController: privacyController),
    );
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    expect(find.text('Local privacy guarantee'), findsOneWidget);
    expect(find.text('Stored history entries: 1'), findsOneWidget);
    expect(find.text('Stored diagnostic entries: 1'), findsOneWidget);

    await tester.tap(_switch('Save processing history on this device'));
    await tester.tap(_switch('Save privacy-safe diagnostics'));
    await tester.pump();
    expect(controller.state.draft!.historyEnabled, isTrue);
    expect(controller.state.draft!.diagnosticsEnabled, isTrue);

    await tester.tap(find.text('Export diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('safe-export.json'), findsOneWidget);

    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();
    expect(find.text('Stored history entries: 0'), findsOneWidget);
  });

  testWidgets('managed exports remain clearable after diagnostics expire',
      (tester) async {
    final controller = _controller();
    final privacyController = PrivacyActivityController(
      repository: _MemoryPrivacyRepository(
        initial: PrivacyActivitySnapshot(
          history: const [],
          diagnostics: const [],
          managedExportPaths: const ['safe-export.json'],
        ),
      ),
    );
    await controller.initialize();
    await privacyController.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
      await privacyController.close();
    });

    await tester.pumpWidget(
      _app(controller, privacyController: privacyController),
    );
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    final clearButton = tester.widget<AppButton>(
      _button('Clear diagnostics'),
    );
    expect(clearButton.onPressed, isNotNull);
  });

  testWidgets('load failure keeps both destructive recovery actions enabled',
      (tester) async {
    final controller = _controller();
    final privacyController = PrivacyActivityController(
      repository: _LoadFailingPrivacyRepository(),
    );
    await controller.initialize();
    await privacyController.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
      await privacyController.close();
    });

    await tester.pumpWidget(
      _app(controller, privacyController: privacyController),
    );
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    final clearHistory = tester.widget<AppButton>(
      _button('Clear history'),
    );
    final clearDiagnostics = tester.widget<AppButton>(
      _button('Clear diagnostics'),
    );
    expect(clearHistory.onPressed, isNotNull);
    expect(clearDiagnostics.onPressed, isNotNull);
  });

  testWidgets('compact pseudo locale is layout-safe with large text',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(700, 720));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(
      _app(
        controller,
        locale: const Locale('en', 'XA'),
        textScaler: const TextScaler.linear(1.5),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SettingsWindow), findsOneWidget);
  });

  testWidgets('compact settings mirror safely in RTL with large text',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(700, 720));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(
      _app(
        controller,
        textScaler: const TextScaler.linear(1.5),
        textDirection: TextDirection.rtl,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SettingsWindow), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byType(SettingsWindow))),
      TextDirection.rtl,
    );
  });

  testWidgets('selected settings section is exposed to assistive technology',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    addTearDown(controller.close);

    await tester.pumpWidget(_app(controller));

    final semantics = tester.getSemantics(
      find.byKey(
        ValueKey(
          'settings-navigation-general',
        ),
      ),
    );
    expect(
      semantics.getSemanticsData().flagsCollection.isSelected,
      Tristate.isTrue,
    );
  });

  testWidgets('settings switches expose their localized purpose and state',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    addTearDown(controller.close);

    await tester.pumpWidget(_app(controller));

    final switchFinder = find.bySemanticsLabel('Launch at startup');
    expect(switchFinder, findsOneWidget);
    final semantics = tester.getSemantics(switchFinder);
    final data = semantics.getSemanticsData();
    expect(data.flagsCollection.isToggled, Tristate.isFalse);
  });

  testWidgets('manual mode replaces misleading shortcut editors with guidance',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(_app(controller, shortcutsAvailable: false));
    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();

    expect(find.text('Global shortcuts need portal support'), findsOneWidget);
    expect(find.text('Show assistant'), findsNothing);

    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Manual mode keeps'), findsOneWidget);
    expect(find.byType(AppSelect<ClipboardPolicy>), findsNothing);
  });

  testWidgets('shortcut controls expose validation and reset/toggle recovery',
      (tester) async {
    final profile = KeyBindingProfile.defaults().copyWith(bindings: {
      ShortcutAction.showOverlay: KeyChord(key: '', modifiers: const {}),
      ShortcutAction.emojify: KeyChord(key: 'Nope', modifiers: const {}),
      ShortcutAction.rewrite: KeyChord(
        key: 'Delete',
        modifiers: const {KeyModifier.control, KeyModifier.alt},
      ),
      ShortcutAction.fix: KeyChord(
        key: 'Delete',
        modifiers: const {KeyModifier.control, KeyModifier.alt},
      ),
    });
    final settings = AppSettings.defaults().copyWith(profiles: [profile]);
    final controller = _controller(settings);
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a key.'), findsOneWidget);
    expect(find.text('Add at least one modifier key.'), findsNWidgets(2));
    expect(
      find.text('This key cannot be registered as a global shortcut.'),
      findsOneWidget,
    );
    expect(
      find.text('This combination is reserved by the operating system.'),
      findsNWidgets(2),
    );
    expect(
      find.text('This combination is already assigned to another action.'),
      findsNWidgets(2),
    );

    final fixGroup = find.byWidgetPredicate(
      (widget) =>
          widget is SettingGroup &&
          widget.title == 'Fix errors in selected text',
    );
    final fixSwitch = find.descendant(
      of: fixGroup,
      matching: find.byType(AppSwitch),
    );
    tester.widget<AppSwitch>(fixSwitch).onChanged(false);
    await tester.pump();
    expect(
      controller
          .state.draft!.activeProfile.bindings[ShortcutAction.fix]!.enabled,
      isFalse,
    );
    tester
        .widget<AppIconButton>(
          find.descendant(
            of: fixGroup,
            matching: _iconButton('Reset shortcut'),
          ),
        )
        .onPressed!();
    await tester.pump();
    expect(
      controller.state.draft!.activeProfile.bindings[ShortcutAction.fix],
      KeyBindingProfile.defaults().bindings[ShortcutAction.fix],
    );
  });

  testWidgets('iOS shortcut issues explain the unsupported platform',
      (tester) async {
    final controller = _controller(
      AppSettings.defaults(),
      null,
      ShortcutPlatform.ios,
    );
    await controller.initialize();
    addTearDown(controller.close);

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();

    expect(
      find.text('Global shortcuts are not available on this platform.'),
      findsWidgets,
    );
  });

  testWidgets('shows compositor-assigned Wayland triggers and recovery actions',
      (tester) async {
    final controller = _controller();
    await controller.initialize();
    addTearDown(controller.close);
    var configured = 0;
    var retried = 0;
    final active = HotkeyRuntimeState(
      phase: HotkeyRuntimePhase.active,
      portalVersion: 2,
      generation: 4,
      bindings: const {
        ShortcutAction.rewrite: HotkeyRuntimeBinding(
          action: ShortcutAction.rewrite,
          desiredTrigger: 'CTRL+ALT+R',
          actualTriggerDescription: 'Ctrl + Alt + R',
        ),
      },
    );

    await tester.pumpWidget(_app(
      controller,
      hotkeyRuntimeState: active,
      onConfigureShortcuts: () => configured++,
      onRetryShortcuts: () => retried++,
    ));
    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Ctrl + Alt + R'), findsOneWidget);
    await tester.tap(find.text('Configure in desktop'));
    expect(configured, 1);

    await tester.pumpWidget(_app(
      controller,
      hotkeyRuntimeState: HotkeyRuntimeState(
        phase: HotkeyRuntimePhase.revoked,
        portalVersion: 2,
        bindings: const {},
      ),
      onConfigureShortcuts: () => configured++,
      onRetryShortcuts: () => retried++,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve shortcuts again'));
    await tester.pump();
    expect(retried, 1);
  });

  testWidgets('narrow large-text footer wraps a localized runtime error',
      (tester) async {
    final controller = _controller(null, _FailingRegistrar());
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(520, 480));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await controller.close();
    });

    await tester.pumpWidget(_app(
      controller,
      locale: const Locale('en', 'XA'),
      textScaler: const TextScaler.linear(2),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('pörtäl shörtcüt'), findsWidgets);
  });
}

Finder _button(String label) => find.widgetWithText(AppButton, label);

Finder _dialogButton(String label) => find.descendant(
      of: find.byType(AppDialog),
      matching: _button(label),
    );

Finder _iconButton(String label) => find.byWidgetPredicate(
      (widget) => widget is AppIconButton && widget.label == label,
    );

Finder _switch(String label) => find.byWidgetPredicate(
      (widget) => widget is AppSwitch && widget.label == label,
    );

Finder _editableText() => find.descendant(
      of: find.byType(AppTextField),
      matching: find.byType(EditableText),
    );

Widget _app(
  SettingsController controller, {
  PrivacyActivityController? privacyController,
  Locale locale = const Locale('en'),
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection? textDirection,
  bool shortcutsAvailable = true,
  bool? manualClipboardMode,
  HotkeyRuntimeState? hotkeyRuntimeState,
  VoidCallback? onConfigureShortcuts,
  VoidCallback? onRetryShortcuts,
  VoidCallback? onSaved,
  bool minimizeOnClose = false,
  VoidCallback? onClosed,
}) {
  final app = BlocProvider.value(
    value: controller,
    child: AppThemeScope(
      brightness: Brightness.light,
      child: WidgetsApp(
        color: const Color(0xFFFFFFFF),
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, __) => builder(context),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        builder: (context, child) => textDirection == null
            ? child!
            : Directionality(textDirection: textDirection, child: child!),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: SettingsWindow(
              onSaved: onSaved ?? () {},
              shortcutsAvailable: shortcutsAvailable,
              manualClipboardMode: manualClipboardMode ?? !shortcutsAvailable,
              hotkeyRuntimeState: hotkeyRuntimeState,
              onConfigureShortcuts: onConfigureShortcuts,
              onRetryShortcuts: onRetryShortcuts,
              minimizeOnClose: minimizeOnClose,
              onClosed: onClosed,
            ),
          ),
        ),
      ),
    ),
  );
  if (privacyController != null) {
    return BlocProvider.value(value: privacyController, child: app);
  }
  return BlocProvider(
    create: (_) => PrivacyActivityController(
      repository: _MemoryPrivacyRepository(empty: true),
    ),
    child: app,
  );
}

SettingsController _controller([
  AppSettings? settings,
  HotkeyRegistrar? registrar,
  ShortcutPlatform platform = ShortcutPlatform.windows,
]) =>
    SettingsController(
      repository: _MemorySettingsRepository(settings),
      hotkeyRegistrar: registrar ?? _NoOpRegistrar(),
      platform: platform,
      onShortcutTriggered: (_) {},
    );

final class _MemorySettingsRepository implements SettingsRepository {
  _MemorySettingsRepository([AppSettings? value])
      : value = value ?? AppSettings.defaults();

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

final class _FailingRegistrar implements HotkeyRegistrar {
  @override
  Future<void> replaceProfile({
    required KeyBindingProfile previous,
    required KeyBindingProfile next,
    required void Function(ShortcutAction action) onTriggered,
  }) =>
      throw const HotkeyRegistrationException(
        kind: HotkeyRegistrationFailureKind.platformError,
        diagnosticCode: 'wayland_global_shortcuts_registration_failed',
      );

  @override
  Future<void> unregisterAll() async {}
}

final class _MemoryPrivacyRepository implements PrivacyActivityRepository {
  _MemoryPrivacyRepository(
      {bool empty = false, PrivacyActivitySnapshot? initial})
      : value = initial ??
            (empty
                ? PrivacyActivitySnapshot.empty()
                : PrivacyActivitySnapshot(
                    history: [
                      PrivacyHistoryEntry(
                        occurredAt: DateTime.utc(2026, 7, 13, 12),
                        action: TextAction.fix,
                        outcome: PrivacyActivityOutcome.completed,
                      ),
                    ],
                    diagnostics: [
                      PrivacyActivityEvent(
                        occurredAt: DateTime.utc(2026, 7, 13, 12),
                        action: TextAction.fix,
                        outcome: PrivacyActivityOutcome.completed,
                        durationBucket: PrivacyDurationBucket.underOneSecond,
                        platformFamily: PrivacyPlatformFamily.windows,
                        clipboardRestoreSkipped: false,
                      ),
                    ],
                  ));

  PrivacyActivitySnapshot value;

  @override
  Future<PrivacyActivitySnapshot> load() async => value;

  @override
  Future<PrivacyActivitySnapshot> record(
    PrivacyActivityEvent event, {
    required PrivacyConsent consent,
  }) async =>
      value;

  @override
  Future<PrivacyActivitySnapshot> clearHistory() async {
    value = PrivacyActivitySnapshot(
      history: const [],
      diagnostics: value.diagnostics,
      managedExportPaths: value.managedExportPaths,
    );
    return value;
  }

  @override
  Future<PrivacyActivitySnapshot> clearDiagnostics() async {
    value = PrivacyActivitySnapshot(
      history: value.history,
      diagnostics: const [],
    );
    return value;
  }

  @override
  Future<String> exportDiagnostics() async => 'safe-export.json';
}

final class _LoadFailingPrivacyRepository implements PrivacyActivityRepository {
  @override
  Future<PrivacyActivitySnapshot> load() async {
    throw StateError('unreadable privacy storage');
  }

  @override
  Future<PrivacyActivitySnapshot> record(
    PrivacyActivityEvent event, {
    required PrivacyConsent consent,
  }) async =>
      PrivacyActivitySnapshot.empty();

  @override
  Future<PrivacyActivitySnapshot> clearHistory() async =>
      PrivacyActivitySnapshot.empty();

  @override
  Future<PrivacyActivitySnapshot> clearDiagnostics() async =>
      PrivacyActivitySnapshot.empty();

  @override
  Future<String> exportDiagnostics() async => 'safe-export.json';
}
