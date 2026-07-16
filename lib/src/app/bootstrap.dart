import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/app/desktop_surface.dart';
import 'package:yandex_keyboard_desktop/src/app/diagnostic_log.dart';
import 'package:yandex_keyboard_desktop/src/app/desktop_visual_preferences.dart';
import 'package:yandex_keyboard_desktop/src/app/ios_bootstrap.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/settings_window.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/startup_hotkey_error_banner.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/overlay_presenter.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/text_assistant_overlay.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_interaction_channel.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_controller.dart';
import 'package:yandex_keyboard_desktop/src/platform/platform_runtime.dart';
import 'package:yandex_keyboard_desktop/src/platform/tray/system_tray_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/application/privacy_activity_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/data/file_privacy_activity_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_state.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/data/file_settings_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_operation_gate.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/data/yandex_text_processing_repository.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/desktop_hotkey_factory.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_runtime_state.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/noop_hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend_factory.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/uia/win32_uia_process_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/windows_native_clipboard_snapshot.dart';
import 'package:yandex_keyboard_desktop/src/platform/settings/launch_at_startup_settings_applier.dart';
import 'package:yandex_keyboard_desktop/src/platform/settings/text_assistant_settings_applier.dart';

Future<void> bootstrap(List<String> arguments) async {
  if (Platform.isIOS) {
    await bootstrapIos();
    return;
  }
  if (await runWindowsUiaHelperIfRequested(arguments)) return;
  if (runWindowsNativeClipboardProbeIfRequested(arguments)) return;
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();

  final packageInfo = await PackageInfo.fromPlatform();
  launchAtStartup.setup(
    appName: packageInfo.appName,
    appPath: Platform.resolvedExecutable,
    packageName: packageInfo.packageName,
  );

  final supportDirectory = await getApplicationSupportDirectory();
  DiagnosticLog.instance.start(
    '${supportDirectory.path}${Platform.pathSeparator}diagnostic.log',
  );
  diag('bootstrap: reached Dart entry, support dir = ${supportDirectory.path}');
  final settingsRepository = FileSettingsRepository(
    file: File(
      '${supportDirectory.path}${Platform.pathSeparator}settings.json',
    ),
  );
  final platformRuntime = createPlatformRuntime();
  final overlayGateway = platformRuntime.overlay;
  final httpClient = http.Client();
  final textPolicyProvider = MutableTextAssistantRuntimePolicyProvider();
  final privacyActivityController = PrivacyActivityController(
    repository: FilePrivacyActivityRepository(
      historyFile: File(
        '${supportDirectory.path}${Platform.pathSeparator}history.v1.json',
      ),
      diagnosticsFile: File(
        '${supportDirectory.path}${Platform.pathSeparator}diagnostics.v1.json',
      ),
      exportDirectory: Directory(
        '${supportDirectory.path}${Platform.pathSeparator}exports',
      ),
      consentProvider: textPolicyProvider,
    ),
  );
  final selectionBackend =
      await createSelectionBackend(platformRuntime.selection);
  final textController = TextReplacementController(
    selectionBackend: selectionBackend,
    processingRepository: YandexTextProcessingRepository(
      client: httpClient,
      policyProvider: textPolicyProvider,
    ),
    policyProvider: textPolicyProvider,
    activityRecorder: privacyActivityController,
    platformFamily: _privacyPlatformFamily,
    onDispose: () async {
      if (selectionBackend is SelectionBackendLifecycle) {
        await (selectionBackend as SelectionBackendLifecycle)
            .prepareForShutdown();
      }
      httpClient.close();
    },
  );
  final textOperationGate = TextOperationGate();
  final overlayPresenter = OverlayPresenter();
  final overlayInteraction = Platform.isWindows
      ? MethodChannelOverlayInteraction()
      : const NoopOverlayInteraction();
  final hotkeyRegistrar = createDesktopHotkeyRegistrar(
    isLinux: Platform.isLinux,
    requiresManualPaste: textController.requiresManualPaste,
    environment: Platform.environment,
  );
  final textSettingsApplier =
      TextAssistantSettingsApplier(policyProvider: textPolicyProvider);
  late final SettingsController settingsController;
  settingsController = SettingsController(
    repository: settingsRepository,
    hotkeyRegistrar: hotkeyRegistrar,
    platform: _shortcutPlatform,
    runtimeApplier: CompositeSettingsRuntimeApplier([
      const LaunchAtStartupSettingsApplier(),
      textSettingsApplier,
    ]),
    draftPrivacyApplier: textSettingsApplier,
    onShortcutTriggered: (action) {
      diag('shortcut triggered: ${action.name} '
          '(canStart=${settingsController.canStartTextOperation}, '
          'busy=${textController.state.isBusy})');
      if (!settingsController.canStartTextOperation) return;
      if (action == ShortcutAction.showOverlay) {
        overlayPresenter.show();
        return;
      }
      if (textController.state.isBusy) return;
      final permit = textOperationGate.tryAcquire();
      if (permit == null) {
        diag('shortcut ${action.name}: gate busy, ignored');
        return;
      }
      unawaited(() async {
        try {
          if (textController.requiresManualPaste) {
            overlayGateway.setOriginalForegroundWindow(0);
          } else {
            overlayGateway.setOriginalForegroundWindow(
              await overlayGateway.getForegroundWindow(),
            );
          }
          final outcome = await textController.run(_textActionFor(action));
          diag('shortcut ${action.name}: outcome=${outcome.name} '
              'stage=${textController.state.stage.name} '
              'failureCode=${textController.state.failureCode}');
        } catch (error) {
          diag('shortcut ${action.name}: threw $error');
          await textController.reportTriggerFailure(
            action: _textActionFor(action),
            diagnosticCode: 'selection_target_capture_failed',
          );
        } finally {
          permit.release();
        }
      }());
    },
  );
  await settingsController.initialize();
  diag('settings initialized: registrar=${hotkeyRegistrar.runtimeType}, '
      'errorCode=${settingsController.state.errorCode}, '
      'manualPaste=${textController.requiresManualPaste}');
  for (var attempt = 0;
      attempt < 3 && settingsController.state.errorCode != null;
      attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await settingsController.retryHotkeyRegistration();
    diag(
        'hotkey retry $attempt: errorCode=${settingsController.state.errorCode}');
  }
  await privacyActivityController.initialize();

  final manualDesktopMode = textController.requiresManualPaste;
  final persistentDesktopEntry = requiresPersistentDesktopEntry(
    manualClipboardMode: manualDesktopMode,
  );
  final initialOverlaySize = overlayWindowSizeFor(
    TextScaler.noScaling,
    manualClipboardMode: manualDesktopMode,
  );
  final windowOptions = WindowOptions(
    size: initialOverlaySize,
    center: true,
    backgroundColor: const Color(0x00000000),
    skipTaskbar: !persistentDesktopEntry,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setPreventClose(true);
    await OverlayWindowController.initialize();
  });
  var glassEnabled = false;
  if (overlayGateway case final OverlayMaterialGateway material) {
    try {
      glassEnabled = await material.applyGlassMaterial();
    } catch (_) {
      glassEnabled = false;
    }
  }

  runApp(
    MultiProvider(
      providers: [
        BlocProvider.value(value: textController),
        BlocProvider.value(value: settingsController),
        BlocProvider.value(value: privacyActivityController),
        Provider<OverlayWindowGateway>.value(value: overlayGateway),
        Provider<TextOperationGate>.value(value: textOperationGate),
        Provider<SettingsRepository>.value(value: settingsRepository),
      ],
      child: App(
        settingsController: settingsController,
        textController: textController,
        privacyActivityController: privacyActivityController,
        hotkeyRegistrar: hotkeyRegistrar,
        textOperationGate: textOperationGate,
        overlayGateway: overlayGateway,
        overlayPresenter: overlayPresenter,
        overlayInteraction: overlayInteraction,
        glassEnabled: glassEnabled,
      ),
    ),
  );
  if (persistentDesktopEntry) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        await OverlayWindowController.initialize(size: initialOverlaySize);
        await windowManager.center();
        await _showOverlayWindowInactive(overlayGateway);
      }());
    });
  }
}

Future<void> _setNativeWindowCanActivate(
  OverlayWindowGateway gateway,
  bool canActivate,
) async {
  if (gateway case final NativeOwnedOverlayActivationGateway activation) {
    await activation.setOwnedWindowCanActivate(canActivate);
    return;
  }
  if (gateway case final NativeOverlayActivationGateway activation) {
    final handle = await gateway.getFlutterWindowHandle();
    if (handle != 0) activation.setWindowCanActivate(handle, canActivate);
  }
}

Future<void> _showOverlayWindowInactive(
  OverlayWindowGateway gateway,
) async {
  if (gateway case final NativeOwnedOverlayActivationGateway activation) {
    await activation.showOwnedWindowInactive();
    return;
  }
  if (gateway case final NativeOverlayActivationGateway activation) {
    final handle = await gateway.getFlutterWindowHandle();
    if (handle != 0) {
      activation.setWindowCanActivate(handle, false);
      activation.showWindowInactive(handle);
      return;
    }
  }
  await windowManager.show(inactive: true);
}

ShortcutPlatform get _shortcutPlatform {
  if (Platform.isWindows) return ShortcutPlatform.windows;
  if (Platform.isLinux) return ShortcutPlatform.linux;
  return ShortcutPlatform.ios;
}

TextAction _textActionFor(ShortcutAction action) => switch (action) {
      ShortcutAction.emojify => TextAction.emojify,
      ShortcutAction.rewrite => TextAction.rewrite,
      ShortcutAction.fix => TextAction.fix,
      ShortcutAction.showOverlay => throw ArgumentError.value(action),
    };

PrivacyPlatformFamily get _privacyPlatformFamily {
  if (Platform.isWindows) return PrivacyPlatformFamily.windows;
  if (Platform.isLinux) return PrivacyPlatformFamily.linux;
  if (Platform.isIOS) return PrivacyPlatformFamily.ios;
  if (Platform.isMacOS) return PrivacyPlatformFamily.macos;
  return PrivacyPlatformFamily.unknown;
}

class App extends StatefulWidget {
  const App({
    super.key,
    required this.settingsController,
    required this.textController,
    required this.privacyActivityController,
    required this.hotkeyRegistrar,
    required this.textOperationGate,
    required this.overlayGateway,
    required this.overlayPresenter,
    required this.overlayInteraction,
    this.glassEnabled = false,
  });

  final SettingsController settingsController;
  final TextReplacementController textController;
  final PrivacyActivityController privacyActivityController;
  final HotkeyRegistrar hotkeyRegistrar;
  final TextOperationGate textOperationGate;
  final OverlayWindowGateway overlayGateway;
  final OverlayPresenter overlayPresenter;
  final OverlayInteractionChannel overlayInteraction;
  final bool glassEnabled;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App>
    with TrayListener, WindowListener, WidgetsBindingObserver {
  String? _hotKeyErrorCode;
  DesktopSurface _surface = DesktopSurface.overlay;
  bool _shutdownInProgress = false;
  bool _resourcesClosed = false;
  int? _pendingTrayTarget;
  String? _trayLocaleTag;
  StreamSubscription<HotkeyRuntimeState>? _hotkeyRuntimeSubscription;
  HotkeyRuntimeState? _hotkeyRuntimeState;
  final _settingsWindowKey = GlobalKey<SettingsWindowState>();
  Future<void> _surfaceTransitionTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    final runtimeSource = widget.hotkeyRegistrar;
    if (runtimeSource is HotkeyRuntimeSource) {
      final source = runtimeSource as HotkeyRuntimeSource;
      _hotkeyRuntimeState = source.state;
      _hotkeyRuntimeSubscription = source.states.listen((state) {
        if (mounted) setState(() => _hotkeyRuntimeState = state);
      });
    }
    final settingsState = widget.settingsController.state;
    if (settingsState.errorCode == 'keybinding_registration_failed' ||
        settingsState.errorCode == 'keybinding_registration_rollback_failed') {
      _hotKeyErrorCode = settingsState.errorCode;
    }
    if (_hotKeyErrorCode != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showHotKeyErrorSurface());
      });
    }
    if (kDebugMode) {
      final settingsDelay = int.tryParse(
        Platform.environment['YKD_TEST_OPEN_SETTINGS_MS'] ?? '',
      );
      if (settingsDelay != null &&
          settingsDelay > 0 &&
          settingsDelay <= 10000) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(() async {
            await Future<void>.delayed(
              Duration(milliseconds: settingsDelay),
            );
            if (mounted) await _openSettingsWindow();
          }());
        });
      }
      final overlayDelay = int.tryParse(
        Platform.environment['YKD_TEST_SHOW_OVERLAY_MS'] ?? '',
      );
      if (overlayDelay != null && overlayDelay > 0 && overlayDelay <= 10000) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(() async {
            await Future<void>.delayed(Duration(milliseconds: overlayDelay));
            if (mounted) await _showOverlayWindow();
          }());
        });
      }
    }
  }

  Future<void> _showHotKeyErrorSurface() =>
      _runSurfaceTransition(_showHotKeyErrorSurfaceNow);

  Future<void> _showHotKeyErrorSurfaceNow() async {
    if (mounted && _surface != DesktopSurface.overlay) {
      setState(() => _surface = DesktopSurface.overlay);
      await WidgetsBinding.instance.endOfFrame;
    }
    const size = Size(460, 96);
    await windowManager.setMinimumSize(size);
    await windowManager.setSize(size);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.center();
    await _showOverlayWindowInactive(widget.overlayGateway);
  }

  Future<void> _dismissHotKeyErrorSurface() =>
      _runSurfaceTransition(_dismissHotKeyErrorSurfaceNow);

  Future<void> _dismissHotKeyErrorSurfaceNow() async {
    if (mounted) setState(() => _hotKeyErrorCode = null);
    await windowManager.hide();
    await _restoreOverlayWindowNow();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_initializeTray());
  }

  Future<void> _initializeTray() async {
    final locale = _effectiveLocale;
    final localeTag = locale.toLanguageTag();
    if (_trayLocaleTag == localeTag) return;
    _trayLocaleTag = localeTag;
    final strings = lookupAppLocalizations(locale);
    try {
      await SystemTrayController.initialize(
        strings.showWindow,
        strings.config,
        strings.exitApp,
      );
    } catch (_) {
      if (_trayLocaleTag == localeTag) _trayLocaleTag = null;
    }
  }

  @override
  void onWindowEvent(String eventName) {
    if (eventName == 'hide') {
      unawaited(_runSurfaceTransition(_handleWindowHiddenNow));
    }
  }

  Future<void> _handleWindowHiddenNow() async {
    widget.textOperationGate.reset();
    if (_hotKeyErrorCode == null) await _restoreOverlayWindowNow();
  }

  @override
  void dispose() {
    if (!_resourcesClosed) {
      unawaited(_closeHotkeyRegistrar().catchError((_) {}));
      unawaited(widget.settingsController.close());
      unawaited(widget.textController.close());
      unawaited(widget.privacyActivityController.close());
    }
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_hotkeyRuntimeSubscription?.cancel());
    super.dispose();
  }

  @override
  void onTrayIconMouseDown() => unawaited(_openTrayMenu());

  Future<void> _openTrayMenu() async {
    try {
      _pendingTrayTarget =
          await captureExternalForegroundWindow(widget.overlayGateway);
    } catch (_) {
      _pendingTrayTarget = null;
    }
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        if (_hotKeyErrorCode == null) {
          final target = _pendingTrayTarget;
          _pendingTrayTarget = null;
          unawaited(
            _showOverlayWindow(targetHandle: target, captureTarget: false),
          );
        } else {
          unawaited(_showHotKeyErrorSurface());
        }
      case 'config':
        _pendingTrayTarget = null;
        unawaited(_openSettingsWindow());
      case 'exit_app':
        _pendingTrayTarget = null;
        unawaited(_requestAppExit());
    }
  }

  String? _formatConflictedChords(SettingsState state) {
    final bindings = state.authoritative?.activeProfile.bindings;
    if (bindings == null || state.conflictedShortcuts.isEmpty) return null;
    final labels = [
      for (final action in state.conflictedShortcuts)
        if (bindings[action] case final chord?)
          chord.format(_shortcutPlatform, upcaseSingleChar: true),
    ];
    return labels.isEmpty ? null : labels.join(', ');
  }

  Future<bool> _confirmSettingsExitIfNeeded() async {
    if (!widget.settingsController.state.isDirty) return true;
    return await _settingsWindowKey.currentState?.confirmDiscardIfNeeded() ??
        false;
  }

  Future<void> _requestAppExit() async {
    var allowed = false;
    await _runSurfaceTransition(() async {
      allowed = await _confirmSettingsExitIfNeeded();
    });
    if (allowed) await windowManager.close();
  }

  @override
  Future<void> onWindowClose() async {
    if (_shutdownInProgress) return;
    await _surfaceTransitionTail.catchError((_) {});
    if (!await _confirmSettingsExitIfNeeded()) return;
    _shutdownInProgress = true;
    var safeToClose = false;
    try {
      safeToClose = await widget.textController.prepareForShutdown();
    } catch (_) {
      safeToClose = false;
    }
    if (!safeToClose) {
      _shutdownInProgress = false;
      await windowManager.setSize(const Size(560, 220));
      await windowManager.center();
      await windowManager.show();
      return;
    }

    await _bestEffort(_closeHotkeyRegistrar);
    await _bestEffort(widget.settingsController.close);
    await _bestEffort(widget.textController.close);
    await _bestEffort(widget.privacyActivityController.close);
    await _bestEffort(trayManager.destroy);
    _resourcesClosed = true;
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {
      _shutdownInProgress = false;
    }
  }

  Future<void> _bestEffort(FutureOr<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {}
  }

  Future<void> _closeHotkeyRegistrar() {
    final registrar = widget.hotkeyRegistrar;
    return registrar is HotkeyRegistrarLifecycle
        ? (registrar as HotkeyRegistrarLifecycle).close()
        : registrar.unregisterAll();
  }

  Future<void> _runSurfaceTransition(
    Future<void> Function() transition,
  ) {
    final result = _surfaceTransitionTail.then((_) => transition());
    _surfaceTransitionTail = result.catchError((_) {});
    return result;
  }

  Future<void> _openSettingsWindow() =>
      _runSurfaceTransition(_openSettingsWindowNow);

  Future<void> _openSettingsWindowNow() async {
    if (mounted && _surface != DesktopSurface.settings) {
      setState(() => _surface = DesktopSurface.settings);
    }
    await _bestEffort(() => windowManager.setAlwaysOnTop(false));
    await _bestEffort(() async {
      if (!Platform.isLinux ||
          Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty != true ||
          Platform.environment['GDK_BACKEND'] == 'x11') {
        await windowManager.setAsFrameless();
      }
    });
    if (Platform.isWindows) {
      await _bestEffort(() => windowManager.setHasShadow(false));
    }
    await _bestEffort(
      () => windowManager.setMinimumSize(const Size(520, 480)),
    );
    await _bestEffort(() => windowManager.setSize(const Size(860, 620)));
    await _bestEffort(windowManager.center);
    await _bestEffort(() => windowManager.setIgnoreMouseEvents(false));
    await _bestEffort(() => windowManager.setMovable(true));
    try {
      await _setNativeWindowCanActivate(widget.overlayGateway, true);
      await WidgetsBinding.instance.endOfFrame;
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      await _bestEffort(() => _restoreOverlayWindowNow(show: true));
    }
  }

  Future<void> _showOverlayWindow({
    int? targetHandle,
    bool captureTarget = true,
  }) =>
      _runSurfaceTransition(
        () => _showOverlayWindowNow(
          targetHandle: targetHandle,
          captureTarget: captureTarget,
        ),
      );

  Future<void> _showOverlayWindowNow({
    int? targetHandle,
    required bool captureTarget,
  }) async {
    final overlaySize = overlayWindowSizeFor(
      MediaQuery.textScalerOf(context),
      manualClipboardMode: widget.textController.requiresManualPaste,
    );
    if (mounted && _surface != DesktopSurface.overlay) {
      if (_surface == DesktopSurface.settings) {
        if (!await _confirmSettingsExitIfNeeded()) return;
      }
      setState(() => _surface = DesktopSurface.overlay);
    }
    var resolvedTarget = targetHandle;
    if (resolvedTarget == null &&
        captureTarget &&
        !widget.textController.requiresManualPaste) {
      try {
        resolvedTarget =
            await captureExternalForegroundWindow(widget.overlayGateway);
      } catch (_) {
        resolvedTarget = null;
      }
    }
    widget.overlayGateway.setOriginalForegroundWindow(resolvedTarget ?? 0);
    await OverlayWindowController.initialize(
      size: overlaySize,
    );
    await WidgetsBinding.instance.endOfFrame;
    await _showOverlayWindowInactive(widget.overlayGateway);
  }

  Future<void> _restoreOverlayWindowNow({bool show = false}) async {
    final overlaySize = overlayWindowSizeFor(
      MediaQuery.textScalerOf(context),
      manualClipboardMode: widget.textController.requiresManualPaste,
    );
    if (mounted && _surface != DesktopSurface.overlay) {
      setState(() => _surface = DesktopSurface.overlay);
      await WidgetsBinding.instance.endOfFrame;
    }
    await OverlayWindowController.initialize(size: overlaySize);
    if (show) {
      await _showOverlayWindowInactive(widget.overlayGateway);
    } else {
      await _setNativeWindowCanActivate(widget.overlayGateway, false);
    }
  }

  Future<void> _restoreManualOverlay() =>
      _runSurfaceTransition(_restoreOverlayWindowNow);

  @override
  void didChangeLocales(List<Locale>? locales) {
    unawaited(_initializeTray());
  }

  Locale get _effectiveLocale {
    final configured = widget.settingsController.state.draft?.locale ??
        widget.settingsController.state.authoritative?.locale ??
        'system';
    return resolveDesktopLocale(
      configuredLocale: configured,
      systemLocale: WidgetsBinding.instance.platformDispatcher.locale,
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SettingsController, SettingsState>(
      listener: (context, state) {
        unawaited(_initializeTray());
        if (state.errorCode == 'keybinding_registration_failed' ||
            state.errorCode == 'keybinding_registration_conflict' ||
            state.errorCode == 'keybinding_registration_rollback_failed') {
          setState(() => _hotKeyErrorCode = state.errorCode);
          unawaited(_showHotKeyErrorSurface());
        }
      },
      builder: (context, state) {
        final settings = state.draft ?? AppSettings.defaults();
        return WidgetsApp(
          debugShowCheckedModeBanner: false,
          color: AppColors.brand,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: settings.locale == 'system' ? null : Locale(settings.locale),
          textStyle: const TextStyle(fontSize: 13, height: 1.35),
          pageRouteBuilder: <T>(routeSettings, builder) => PageRouteBuilder<T>(
            settings: routeSettings,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, _, __) => builder(context),
          ),
          home: Builder(
            builder: (context) {
              final brightness = resolveDesktopBrightness(
                preference: settings.theme,
                systemBrightness: MediaQuery.platformBrightnessOf(context),
              );
              return AppGlassScope(
                enabled: widget.glassEnabled,
                child: AppThemeScope(
                  brightness: brightness,
                  child: Builder(
                    builder: (context) => DefaultTextStyle(
                      style: AppTextStyles.body(context),
                      child: DesktopSurfaceHost(
                        surface: _surface,
                        settings: SettingsWindow(
                          key: _settingsWindowKey,
                          shortcutsAvailable:
                              widget.hotkeyRegistrar is! NoOpHotkeyRegistrar,
                          manualClipboardMode:
                              widget.textController.requiresManualPaste,
                          hotkeyRuntimeState: _hotkeyRuntimeState,
                          onConfigureShortcuts: () {
                            final source = widget.hotkeyRegistrar;
                            if (source is HotkeyRuntimeSource) {
                              unawaited(
                                (source as HotkeyRuntimeSource)
                                    .configureShortcuts()
                                    .catchError((_) {}),
                              );
                            }
                          },
                          onRetryShortcuts: () => unawaited(
                            widget.settingsController.retryHotkeyRegistration(),
                          ),
                          minimizeOnClose:
                              widget.textController.requiresManualPaste,
                          onClosed: () {
                            if (!widget.textController.requiresManualPaste ||
                                !mounted) {
                              return;
                            }
                            unawaited(_restoreManualOverlay());
                          },
                          onSaved: () {
                            if (mounted) {
                              setState(() => _hotKeyErrorCode = null);
                            }
                          },
                        ),
                        overlay: _hotKeyErrorCode != null
                            ? Center(
                                child: StartupHotKeyErrorBanner(
                                  rollbackFailed: _hotKeyErrorCode ==
                                      'keybinding_registration_rollback_failed',
                                  conflictedChords:
                                      _formatConflictedChords(state),
                                  onClose: () =>
                                      unawaited(_dismissHotKeyErrorSurface()),
                                ),
                              )
                            : TextAssistantOverlay(
                                presenter: widget.overlayPresenter,
                                interaction: widget.overlayInteraction,
                                onOpenSettings: _openSettingsWindow,
                              ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
