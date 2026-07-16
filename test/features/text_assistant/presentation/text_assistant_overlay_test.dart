import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/data/file_settings_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_operation_gate.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_state.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_processing_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/processing_status_card.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/text_assistant_overlay.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/manual_clipboard_selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/platform_selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> windowCalls;

  setUp(() {
    windowCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        windowCalls.add(call);
        return switch (call.method) {
          'getBounds' => <String, double>{
              'x': 0,
              'y': 0,
              'width': 540,
              'height': 176,
            },
          'isVisible' || 'isFocused' => false,
          'isMinimized' => false,
          _ => null,
        };
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  testWidgets('shows at the cursor and completes the manual workflow',
      (tester) async {
    final settings = _settingsController();
    final clipboard = _MemoryClipboard('Hello overlay');
    final repository = _BlockingRepository();
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(clipboard: clipboard),
      processingRepository: repository,
      policyProvider: const FixedTextAssistantRuntimePolicyProvider(),
    );
    final gateway = _OverlayGateway();
    final overlayKey = GlobalKey<TextAssistantOverlayState>();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });

    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: gateway,
        child: TextAssistantOverlay(key: overlayKey),
      ),
    );
    await tester.pump();

    overlayKey.currentState!.showOverlay();
    await tester.pumpAndSettle();
    expect(gateway.originalForegroundWindow, 0);
    expect(gateway.workAreaRequests, 1);

    final terminal = controller.stream.firstWhere(
      (state) => state.stage == TextReplacementStage.awaitingManualPaste,
    );
    await tester.tap(find.text('Improve'));
    await repository.started.future;
    await tester.pump();
    expect(find.byType(ProcessingStatusCard), findsOneWidget);

    repository.complete('HELLO OVERLAY');
    await terminal;
    await tester.pumpAndSettle();
    expect(find.text('Ready to paste'), findsOneWidget);
    expect(clipboard.value, 'HELLO OVERLAY');

    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is AppIconButton && widget.label == 'Dismiss',
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.state.stage, TextReplacementStage.idle);
  });

  testWidgets('maps every clipboard failure family to truthful recovery UI',
      (tester) async {
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(
        clipboard: _MemoryClipboard('source'),
      ),
      processingRepository: const _ImmediateRepository(),
    );
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: _OverlayGateway(),
        child: const TextAssistantOverlay(),
      ),
    );

    await controller.reportTriggerFailure(
      diagnosticCode: 'clipboard_recovery_manual_action_required',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recovery')), findsOneWidget);

    controller.reset();
    await controller.reportTriggerFailure(
      diagnosticCode: 'windows_clipboard_snapshot_capture_timeout',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('clipboard-fallback')), findsOneWidget);

    controller.reset();
    await controller.reportTriggerFailure(
      diagnosticCode: 'windows_clipboard_snapshot_rollback_failed',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('clipboard-state-review')),
      findsOneWidget,
    );

    controller.reset();
    await controller.reportTriggerFailure(diagnosticCode: 'unknown_failure');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('failure')), findsOneWidget);
  });

  testWidgets('size bounds explain recovery without offering a blind retry',
      (tester) async {
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(
        clipboard: _MemoryClipboard('source'),
      ),
      processingRepository: const _ImmediateRepository(),
    );
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: _OverlayGateway(),
        child: const TextAssistantOverlay(),
      ),
    );

    await controller.reportTriggerFailure(
      action: TextAction.fix,
      diagnosticCode: 'transform_input_too_large',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('input-too-large')), findsOneWidget);
    expect(find.text('Selection is too large'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);

    controller.reset();
    await controller.reportTriggerFailure(
      action: TextAction.fix,
      diagnosticCode: 'transform_response_too_large',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('response-too-large')), findsOneWidget);
    expect(find.text('Response was too large'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('capture failure becomes a cursor-adjacent actionable notice',
      (tester) async {
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(
        clipboard: _MemoryClipboard('source'),
      ),
      processingRepository: const _ImmediateRepository(),
    );
    final overlayKey = GlobalKey<TextAssistantOverlayState>();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: _OverlayGateway(throwOnCursor: true),
        child: TextAssistantOverlay(key: overlayKey),
      ),
    );

    overlayKey.currentState!.showOverlay();
    await tester.pumpAndSettle();

    expect(controller.state.stage, TextReplacementStage.failed);
    expect(controller.state.failureCode, 'selection_target_capture_failed');
    expect(find.byKey(const ValueKey('failure')), findsOneWidget);
  });

  testWidgets('unverified direct replacement confirms success and auto-hides',
      (tester) async {
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: _UnverifiedSelectionBackend(),
      processingRepository: const _ImmediateRepository(),
    );
    final gateway = _OverlayGateway();
    final overlayKey = GlobalKey<TextAssistantOverlayState>();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: gateway,
        child: TextAssistantOverlay(key: overlayKey),
      ),
    );

    overlayKey.currentState!.showOverlay();
    await tester.pump();
    expect(gateway.originalForegroundWindow, 2);

    expect(
      await controller.run(TextAction.fix),
      TextReplacementOutcome.completedWithWarning,
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('success')), findsOneWidget);
    expect(find.byKey(const ValueKey('warning')), findsNothing);

    windowCalls.clear();
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();
    expect(windowCalls.where((call) => call.method == 'hide'), isNotEmpty);
  });

  testWidgets('retry does not bypass an operation already holding the gate',
      (tester) async {
    final settings = _settingsController();
    final repository = _CountingRepository();
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(
        clipboard: _MemoryClipboard('source'),
      ),
      processingRepository: repository,
    );
    final gate = TextOperationGate();
    final competingPermit = gate.tryAcquire()!;
    await settings.initialize();
    addTearDown(() async {
      competingPermit.release();
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: _OverlayGateway(),
        gate: gate,
        child: const TextAssistantOverlay(),
      ),
    );

    await controller.reportTriggerFailure(
      action: TextAction.rewrite,
      diagnosticCode: 'processing_failed',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(repository.calls, 0);
    expect(controller.state.stage, TextReplacementStage.failed);
  });

  testWidgets('stale notice placement cannot reopen after reset',
      (tester) async {
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(
        clipboard: _MemoryClipboard('source'),
      ),
      processingRepository: const _ImmediateRepository(),
    );
    final gateway = _DeferredOverlayGateway();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: gateway,
        child: const TextAssistantOverlay(),
      ),
    );

    await controller.reportTriggerFailure(
      diagnosticCode: 'processing_failed',
    );
    await tester.pump();
    controller.reset();
    gateway.cursor.complete(const Offset(400, 300));
    await tester.pumpAndSettle();

    expect(controller.state.stage, TextReplacementStage.idle);
    expect(find.byKey(const ValueKey('actions')), findsOneWidget);
    expect(windowCalls.where((call) => call.method == 'show'), isEmpty);
  });

  testWidgets('successful clipboard recovery restores compact action bounds',
      (tester) async {
    final settings = _settingsController();
    final backend = _RecoverySelectionBackend();
    final controller = TextReplacementController(
      selectionBackend: backend,
      processingRepository: const _ImmediateRepository(),
    );
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: _OverlayGateway(),
        child: const TextAssistantOverlay(),
      ),
    );

    await controller.reportTriggerFailure(
      diagnosticCode: 'clipboard_recovery_manual_action_required',
    );
    await tester.pumpAndSettle();
    windowCalls.clear();
    await tester.tap(find.text('Retry recovery'));
    await tester.pumpAndSettle();

    expect(controller.state.stage, TextReplacementStage.idle);
    expect(find.byKey(const ValueKey('actions')), findsOneWidget);
    expect(
      windowCalls.where((call) {
        if (call.method != 'setBounds') return false;
        final arguments = call.arguments as Map<Object?, Object?>;
        return arguments['width'] == 384.0 && arguments['height'] == 44.0;
      }),
      isNotEmpty,
    );
  });

  testWidgets('placement failure releases the gate for the next trigger',
      (tester) async {
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(
        clipboard: _MemoryClipboard('source'),
      ),
      processingRepository: const _ImmediateRepository(),
    );
    final gateway = _OverlayGateway(throwOnCursor: true);
    final overlayKey = GlobalKey<TextAssistantOverlayState>();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: gateway,
        child: TextAssistantOverlay(key: overlayKey),
      ),
    );

    overlayKey.currentState!.showOverlay();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is AppIconButton && widget.label == 'Dismiss',
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.state.stage, TextReplacementStage.idle);
    expect(find.byKey(const ValueKey('actions')), findsOneWidget);
    overlayKey.currentState!.showOverlay();
    await tester.pumpAndSettle();

    expect(gateway.cursorRequests, 4);
  });

  testWidgets('a prior terminal error cannot poison the next trigger',
      (tester) async {
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(
        clipboard: _MemoryClipboard('source'),
      ),
      processingRepository: const _ImmediateRepository(),
    );
    final overlayKey = GlobalKey<TextAssistantOverlayState>();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: _OverlayGateway(),
        child: TextAssistantOverlay(key: overlayKey),
      ),
    );

    await controller.reportTriggerFailure(
      diagnosticCode: 'processing_failed',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('failure')), findsOneWidget);

    overlayKey.currentState!.showOverlay();
    await tester.pumpAndSettle();

    expect(controller.state.stage, TextReplacementStage.idle);
    expect(find.byKey(const ValueKey('actions')), findsOneWidget);
  });

  testWidgets('manual clipboard recovery remains mandatory after hiding',
      (tester) async {
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: _RecoverySelectionBackend(),
      processingRepository: const _ImmediateRepository(),
    );
    final overlayKey = GlobalKey<TextAssistantOverlayState>();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: _OverlayGateway(),
        child: TextAssistantOverlay(key: overlayKey),
      ),
    );

    await controller.reportTriggerFailure(
      diagnosticCode: 'clipboard_recovery_manual_action_required',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is AppIconButton && widget.label == 'Dismiss',
      ),
    );
    await tester.pumpAndSettle();
    overlayKey.currentState!.showOverlay();
    await tester.pumpAndSettle();

    expect(controller.state.failureCode,
        'clipboard_recovery_manual_action_required');
    expect(find.byKey(const ValueKey('recovery')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions')), findsNothing);
    expect(
      windowCalls.where((call) {
        if (call.method != 'setBounds') return false;
        final arguments = call.arguments as Map<Object?, Object?>;
        return arguments['width'] == 480.0 && arguments['height'] == 176.0;
      }),
      isNotEmpty,
    );
  });

  testWidgets(
      'repeating the global shortcut recovers without activating the overlay',
      (tester) async {
    final backend = _RecoverySelectionBackend();
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: backend,
      processingRepository: const _ImmediateRepository(),
    );
    final overlayKey = GlobalKey<TextAssistantOverlayState>();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        windowCalls.add(call);
        return switch (call.method) {
          'isVisible' => true,
          'isMinimized' || 'isFocused' => false,
          _ => null,
        };
      },
    );
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: _OverlayGateway(),
        child: TextAssistantOverlay(key: overlayKey),
      ),
    );

    await controller.reportTriggerFailure(
      diagnosticCode: 'clipboard_recovery_manual_action_required',
    );
    await tester.pumpAndSettle();
    overlayKey.currentState!.showOverlay();
    await tester.pumpAndSettle();

    expect(backend.recoveryRequired, isFalse);
    expect(controller.state.stage, TextReplacementStage.idle);
    expect(find.byKey(const ValueKey('actions')), findsOneWidget);
    expect(windowCalls.where((call) => call.method == 'focus'), isEmpty);
  });

  testWidgets('stale native placement is discarded before its mutation',
      (tester) async {
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(
        clipboard: _MemoryClipboard('source'),
      ),
      processingRepository: const _ImmediateRepository(),
    );
    final gateway = _DeferredNativeOverlayGateway();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: gateway,
        child: const TextAssistantOverlay(),
      ),
    );

    await controller.reportTriggerFailure(
      diagnosticCode: 'processing_failed',
    );
    await tester.pump();
    controller.reset();
    gateway.placement.complete(
      const NativeOverlayPlacement(
        nativeWindowHandle: 1,
        nativeBounds: Rect.fromLTWH(100, 100, 420, 60),
        logicalSize: Size(420, 60),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.applyCalls, 0);
    expect(windowCalls.where((call) => call.method == 'show'), isEmpty);
  });

  testWidgets('foreground loss cancels a pending mandatory recovery placement',
      (tester) async {
    var visible = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        windowCalls.add(call);
        if (call.method == 'hide') visible = false;
        return switch (call.method) {
          'isVisible' => visible,
          'isMinimized' || 'isFocused' => false,
          _ => null,
        };
      },
    );
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: _RecoverySelectionBackend(),
      processingRepository: const _ImmediateRepository(),
    );
    final gateway = _DeferredNativeOverlayGateway();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: gateway,
        child: const TextAssistantOverlay(),
      ),
    );

    await controller.reportTriggerFailure(
      diagnosticCode: 'clipboard_recovery_manual_action_required',
    );
    await tester.pump();
    expect(gateway.placement.isCompleted, isFalse);

    gateway.currentForegroundWindow = 3;
    await tester.pump(const Duration(milliseconds: 150));
    expect(windowCalls.where((call) => call.method == 'hide'), isNotEmpty);

    gateway.placement.complete(
      const NativeOverlayPlacement(
        nativeWindowHandle: 1,
        nativeBounds: Rect.fromLTWH(100, 100, 480, 176),
        logicalSize: Size(480, 176),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.applyCalls, 0);
    expect(gateway.inactiveShows, isEmpty);
    expect(
      controller.state.failureCode,
      'clipboard_recovery_manual_action_required',
    );
  });

  testWidgets('native popup is shown without activating the window',
      (tester) async {
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(
        clipboard: _MemoryClipboard('source'),
      ),
      processingRepository: const _ImmediateRepository(),
    );
    final gateway = _DeferredNativeOverlayGateway();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: gateway,
        child: const TextAssistantOverlay(),
      ),
    );

    await controller.reportTriggerFailure(
      diagnosticCode: 'processing_failed',
    );
    gateway.placement.complete(
      const NativeOverlayPlacement(
        nativeWindowHandle: 7,
        nativeBounds: Rect.fromLTWH(100, 100, 420, 60),
        logicalSize: Size(420, 60),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.applyCalls, 1);
    expect(gateway.activationChanges, [(7, false)]);
    expect(gateway.inactiveShows, [7]);
    expect(windowCalls.where((call) => call.method == 'focus'), isEmpty);
  });

  testWidgets('handleless native popup uses the owned inactive-show contract',
      (tester) async {
    final settings = _settingsController();
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(
        clipboard: _MemoryClipboard('source'),
      ),
      processingRepository: const _ImmediateRepository(),
    );
    final gateway = _OwnedOverlayGateway();
    await settings.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settings.close();
      await controller.close();
    });
    await tester.pumpWidget(
      _app(
        settings: settings,
        controller: controller,
        gateway: gateway,
        child: const TextAssistantOverlay(),
      ),
    );

    await controller.reportTriggerFailure(diagnosticCode: 'processing_failed');
    await tester.pumpAndSettle();

    expect(gateway.activationChanges, isEmpty);
    expect(gateway.inactiveShowCalls, 1);
    expect(windowCalls.where((call) => call.method == 'focus'), isEmpty);
  });
}

Widget _app({
  required SettingsController settings,
  required TextReplacementController controller,
  required OverlayWindowGateway gateway,
  TextOperationGate? gate,
  required Widget child,
}) =>
    MultiProvider(
      providers: [
        BlocProvider.value(value: settings),
        BlocProvider.value(value: controller),
        Provider<OverlayWindowGateway>.value(value: gateway),
        Provider<TextOperationGate>.value(value: gate ?? TextOperationGate()),
      ],
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
          locale: const Locale('en'),
          home: child,
        ),
      ),
    );

SettingsController _settingsController() => SettingsController(
      repository: _MemorySettingsRepository(),
      hotkeyRegistrar: const _NoOpRegistrar(),
      platform: ShortcutPlatform.windows,
      onShortcutTriggered: (_) {},
    );

final class _MemorySettingsRepository implements SettingsRepository {
  AppSettings value = AppSettings.defaults();

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

final class _BlockingRepository implements TextProcessingRepository {
  final started = Completer<void>();
  final _result = Completer<String>();

  void complete(String value) => _result.complete(value);

  @override
  Future<String> process({
    required String text,
    required TextAction action,
    TextAssistantRuntimePolicy? policy,
    TextProcessingCancellationToken? cancellationToken,
  }) {
    if (!started.isCompleted) started.complete();
    return _result.future;
  }
}

final class _ImmediateRepository implements TextProcessingRepository {
  const _ImmediateRepository();

  @override
  Future<String> process({
    required String text,
    required TextAction action,
    TextAssistantRuntimePolicy? policy,
    TextProcessingCancellationToken? cancellationToken,
  }) async =>
      text;
}

final class _CountingRepository implements TextProcessingRepository {
  int calls = 0;

  @override
  Future<String> process({
    required String text,
    required TextAction action,
    TextAssistantRuntimePolicy? policy,
    TextProcessingCancellationToken? cancellationToken,
  }) async {
    calls++;
    return text;
  }
}

final class _UnverifiedSelectionBackend implements SelectionBackend {
  static const target = SelectionTarget('direct-target');

  @override
  Future<SelectionTarget> captureTarget() async => target;

  @override
  void releaseTarget(SelectionTarget target) {}

  @override
  Future<ClipboardSnapshot> snapshotClipboard() async =>
      const ClipboardSnapshot(revision: 1, nativeData: 'source');

  @override
  Future<SelectionCopy> copySelection(
    SelectionTarget target,
    ClipboardSnapshot snapshot, {
    required int maxAttempts,
    required Duration retryDelay,
  }) async =>
      const SelectionCopy(text: 'source', ownedClipboardRevision: 2);

  @override
  Future<bool> isSameTarget(SelectionTarget target) async => true;

  @override
  Future<void> focus(SelectionTarget target) async {}

  @override
  Future<ClipboardLease> stageReplacement(
    SelectionTarget target,
    String text, {
    required int expectedRevision,
    required String rollbackText,
  }) async =>
      ClipboardLease(target: target, clipboardRevision: 3);

  @override
  Future<CommitVerification> commitReplacement(ClipboardLease lease) async =>
      CommitVerification.unverified;

  @override
  Future<ClipboardRestoreResult> restoreClipboard(
    ClipboardSnapshot snapshot, {
    required int expectedRevision,
    bool restoreOriginal = true,
  }) async =>
      ClipboardRestoreResult.restored;
}

final class _RecoverySelectionBackend
    implements SelectionBackend, ClipboardRecoveryBackend {
  bool recoveryRequired = true;

  @override
  bool get clipboardRecoveryRequiresManualAction => recoveryRequired;

  @override
  bool get hasPendingClipboardRecovery => recoveryRequired;

  @override
  Future<bool> retryClipboardRecovery() async {
    recoveryRequired = false;
    return true;
  }

  @override
  Future<SelectionTarget> captureTarget() async =>
      const SelectionTarget('recovery-target');

  @override
  void releaseTarget(SelectionTarget target) {}

  @override
  Future<ClipboardSnapshot> snapshotClipboard() async =>
      const ClipboardSnapshot(revision: 1, nativeData: 'source');

  @override
  Future<SelectionCopy> copySelection(
    SelectionTarget target,
    ClipboardSnapshot snapshot, {
    required int maxAttempts,
    required Duration retryDelay,
  }) async =>
      const SelectionCopy(text: 'source', ownedClipboardRevision: 2);

  @override
  Future<bool> isSameTarget(SelectionTarget target) async => true;

  @override
  Future<void> focus(SelectionTarget target) async {}

  @override
  Future<ClipboardLease> stageReplacement(
    SelectionTarget target,
    String text, {
    required int expectedRevision,
    required String rollbackText,
  }) async =>
      ClipboardLease(target: target, clipboardRevision: 3);

  @override
  Future<CommitVerification> commitReplacement(ClipboardLease lease) async =>
      CommitVerification.verified;

  @override
  Future<ClipboardRestoreResult> restoreClipboard(
    ClipboardSnapshot snapshot, {
    required int expectedRevision,
    bool restoreOriginal = true,
  }) async =>
      ClipboardRestoreResult.restored;
}

final class _DeferredOverlayGateway implements OverlayWindowGateway {
  final cursor = Completer<Offset>();

  @override
  Future<Offset> getCursorPos() => cursor.future;

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

final class _DeferredNativeOverlayGateway
    implements
        OverlayWindowGateway,
        NativeOverlayPlacementGateway,
        NativeOverlayActivationGateway {
  final placement = Completer<NativeOverlayPlacement>();
  int applyCalls = 0;
  final activationChanges = <(int, bool)>[];
  final inactiveShows = <int>[];
  int currentForegroundWindow = 2;
  int originalForegroundWindow = 2;

  @override
  Future<NativeOverlayPlacement> resolveOverlayPlacement({
    required Offset point,
    required Size desiredLogicalSize,
    double logicalGap = 10,
  }) =>
      placement.future;

  @override
  void applyOverlayPlacement(NativeOverlayPlacement placement) {
    applyCalls++;
  }

  @override
  void setWindowCanActivate(int nativeWindowHandle, bool canActivate) {
    activationChanges.add((nativeWindowHandle, canActivate));
  }

  @override
  void showWindowInactive(int nativeWindowHandle) {
    inactiveShows.add(nativeWindowHandle);
  }

  @override
  Future<Offset> getCursorPos() async => const Offset(400, 300);

  @override
  Future<int> getFlutterWindowHandle() async => 1;

  @override
  Future<int> getForegroundWindow() async => currentForegroundWindow;

  @override
  int getOriginalForegroundWindow() => originalForegroundWindow;

  @override
  Future<Size> getScreenSize() async => const Size(1920, 1080);

  @override
  Future<Rect> getWorkAreaForPoint(Offset point) async =>
      const Rect.fromLTWH(0, 0, 1920, 1040);

  @override
  void setOriginalForegroundWindow(int handle) {
    originalForegroundWindow = handle;
  }
}

class _OverlayGateway implements OverlayWindowGateway {
  _OverlayGateway({this.throwOnCursor = false});

  final bool throwOnCursor;
  int originalForegroundWindow = -1;
  int workAreaRequests = 0;
  int cursorRequests = 0;

  @override
  Future<Offset> getCursorPos() async {
    cursorRequests++;
    if (throwOnCursor) throw StateError('cursor metadata unavailable');
    return const Offset(1800, 1000);
  }

  @override
  Future<int> getFlutterWindowHandle() async => 1;

  @override
  Future<int> getForegroundWindow() async => 2;

  @override
  int getOriginalForegroundWindow() => originalForegroundWindow;

  @override
  Future<Size> getScreenSize() async => const Size(1920, 1080);

  @override
  Future<Rect> getWorkAreaForPoint(Offset point) async {
    workAreaRequests++;
    return const Rect.fromLTWH(0, 0, 1920, 1040);
  }

  @override
  void setOriginalForegroundWindow(int handle) {
    originalForegroundWindow = handle;
  }
}

final class _OwnedOverlayGateway extends _OverlayGateway
    implements NativeOwnedOverlayActivationGateway {
  final activationChanges = <bool>[];
  int inactiveShowCalls = 0;

  @override
  Future<void> setOwnedWindowCanActivate(bool canActivate) async {
    activationChanges.add(canActivate);
  }

  @override
  Future<void> showOwnedWindowInactive() async {
    inactiveShowCalls++;
  }
}
