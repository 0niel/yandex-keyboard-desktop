import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yandex_keyboard_desktop/src/app/diagnostic_log.dart';
import 'package:yandex_keyboard_desktop/src/app/frame_settle.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_interaction_channel.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_gateway.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_operation_gate.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_state.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/overlay_presenter.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/processing_status_card.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/replacement_success_card.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/text_action_bar.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_controller.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_surface.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';

const _clipboardFallbackFailureCodes = <String>{
  'clipboard_snapshot_format_unsupported',
  'clipboard_snapshot_gateway_unavailable',
  'native_clipboard_snapshot_gateway_unavailable',
  'windows_clipboard_snapshot_allocation_failed',
  'windows_clipboard_snapshot_capture_timeout',
  'windows_clipboard_snapshot_failed',
  'windows_clipboard_snapshot_format_unsupported',
  'windows_clipboard_snapshot_invalid_result',
  'windows_clipboard_snapshot_too_large',
  'windows_clipboard_snapshot_unavailable',
};

bool requiresManualClipboardFallback(String? failureCode) =>
    _clipboardFallbackFailureCodes.contains(failureCode);

const _clipboardStateReviewFailureCodes = <String>{
  'windows_clipboard_snapshot_rollback_failed',
  'windows_clipboard_snapshot_restore_timeout',
};

bool requiresClipboardStateReview(String? failureCode) =>
    _clipboardStateReviewFailureCodes.contains(failureCode);

class TextAssistantOverlay extends StatefulWidget {
  const TextAssistantOverlay({
    super.key,
    this.onOpenSettings,
    this.presenter,
    this.interaction = const NoopOverlayInteraction(),
  });

  final Future<void> Function()? onOpenSettings;
  final OverlayPresenter? presenter;
  final OverlayInteractionChannel interaction;

  @override
  State<StatefulWidget> createState() => TextAssistantOverlayState();
}

class TextAssistantOverlayState extends State<TextAssistantOverlay> {
  Timer? _focusCheckTimer;
  Future<void> _windowPlacementTail = Future<void>.value();
  int _windowPlacementGeneration = 0;
  OverlayNoticeKind? _presentedNoticeKind;
  bool _isPresenting = false;
  bool _focusCheckInProgress = false;
  bool _dismissing = false;
  int _entranceGeneration = 0;
  Offset? _sessionAnchor;
  bool _sessionShown = false;
  Rect? _lastNativeBounds;
  Timer? _successDismissTimer;
  TextOperationPermit? _permit;

  static const Duration _resizeDuration = Duration(milliseconds: 160);
  static const int _resizeSteps = 10;

  void _resetSession() {
    _sessionAnchor = null;
    _sessionShown = false;
    _lastNativeBounds = null;
    unawaited(widget.interaction.watchOutsideClick(false));
  }

  void _replayEntrance() {
    if (!mounted) return;
    setState(() => _entranceGeneration++);
  }

  @override
  void initState() {
    super.initState();
    widget.presenter?.attach(showOverlay);
    widget.interaction.onOutsideClick = () {
      if (mounted && !_dismissing) unawaited(_dismissWindow());
    };
    _startFocusCheck();
  }

  @override
  void dispose() {
    widget.presenter?.detach(showOverlay);
    widget.interaction.onOutsideClick = null;
    unawaited(widget.interaction.watchOutsideClick(false));
    _focusCheckTimer?.cancel();
    _successDismissTimer?.cancel();
    _invalidateWindowPlacement();
    _releasePermit();
    super.dispose();
  }

  Future<void> _processClipboardText(
      BuildContext context, TextAction action) async {
    try {
      if (!context.read<SettingsController>().canStartTextOperation) return;
      final controller = context.read<TextReplacementController>();
      final outcome = await controller.run(action);
      diag('action-bar ${action.name}: outcome=${outcome.name} '
          'failureCode=${controller.state.failureCode}');
    } finally {
      _releasePermit();
    }
  }

  void showOverlay() async {
    if (!context.read<SettingsController>().canStartTextOperation) return;
    final controller = context.read<TextReplacementController>();
    final platformService = context.read<OverlayWindowGateway>();
    final operationGate = context.read<TextOperationGate>();
    if (_isPresenting || controller.state.isBusy) return;
    if (await windowManager.isVisible()) {
      await _activateVisibleOverlayShortcut(controller);
      return;
    }
    _resetSession();
    if (_canResetTerminalState(controller.state)) {
      controller.reset();
    }
    final retainedNotice = _noticeKindForState(controller.state);
    if (retainedNotice != null) {
      if (_isPresenting) return;
      if (await windowManager.isVisible() &&
          !await windowManager.isMinimized()) {
        return;
      }
      _isPresenting = true;
      try {
        await _enqueueWindowPlacement(
          (generation) => _showNoticeWindow(retainedNotice, generation),
        );
      } finally {
        _isPresenting = false;
      }
      return;
    }
    final permit = operationGate.tryAcquire();
    if (permit == null) return;
    _permit = permit;
    _isPresenting = true;
    try {
      if (await windowManager.isVisible()) {
        _releasePermit();
        return;
      }
      if (controller.requiresManualPaste) {
        platformService.setOriginalForegroundWindow(0);
      } else {
        platformService.setOriginalForegroundWindow(
          await platformService.getForegroundWindow(),
        );
      }
      await _showWindowAtCursor(platformService);
    } catch (_) {
      if (!mounted) return;
      _releasePermit();
      await controller.reportTriggerFailure(
        diagnosticCode: 'selection_target_capture_failed',
      );
    } finally {
      _isPresenting = false;
    }
  }

  void _releasePermit() {
    _permit?.release();
    _permit = null;
  }

  Future<void> _showWindowAtCursor(
    OverlayWindowGateway platformService,
  ) async {
    final overlaySize = overlayWindowSizeFor(
      MediaQuery.maybeOf(context)?.textScaler ?? TextScaler.noScaling,
      manualClipboardMode:
          context.read<TextReplacementController>().requiresManualPaste,
    );
    await _enqueueWindowPlacement((generation) async {
      final shown = await _placeWindowNearCursor(
        platformService,
        overlaySize,
        generation,
      );
      if (shown) _presentedNoticeKind = null;
    });
  }

  void _startFocusCheck() {
    _focusCheckTimer =
        Timer.periodic(const Duration(milliseconds: 100), (timer) async {
      if (_focusCheckInProgress || !mounted) return;
      _focusCheckInProgress = true;
      try {
        final controller = context.read<TextReplacementController>();
        if (controller.requiresManualPaste) return;
        final platformService =
            Provider.of<OverlayWindowGateway>(context, listen: false);
        if (!await windowManager.isVisible() || controller.state.isBusy) return;
        final hwnd = await platformService.getForegroundWindow();
        final originalWindow = platformService.getOriginalForegroundWindow();
        final flutterWindow = await platformService.getFlutterWindowHandle();

        if (overlayTargetForegroundChanged(
              currentForeground: hwnd,
              originalForeground: originalWindow,
              flutterWindow: flutterWindow,
            ) &&
            await windowManager.isVisible()) {
          _invalidateWindowPlacement();
          _presentedNoticeKind = null;
          _resetSession();
          if (_canResetTerminalState(controller.state)) controller.reset();
          await windowManager.hide();
          _releasePermit();
        }
      } catch (_) {
      } finally {
        _focusCheckInProgress = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0x00000000),
      child: BlocListener<TextReplacementController, TextReplacementState>(
        listener: (context, state) {
          final noticeKind = _noticeKindForState(state);
          if (noticeKind != OverlayNoticeKind.success) {
            _successDismissTimer?.cancel();
            _successDismissTimer = null;
          }
          if (noticeKind == OverlayNoticeKind.success) {
            _scheduleNoticeWindow(noticeKind!);
            _successDismissTimer ??= Timer(
              const Duration(milliseconds: 1100),
              () {
                _successDismissTimer = null;
                if (mounted &&
                    _isUnverifiedSuccess(
                      context.read<TextReplacementController>().state,
                    )) {
                  unawaited(_dismissWindow());
                }
              },
            );
          } else if (noticeKind != null) {
            _scheduleNoticeWindow(noticeKind);
          } else if (state.stage == TextReplacementStage.completed) {
            _invalidateWindowPlacement();
            _presentedNoticeKind = null;
            _resetSession();
            unawaited(windowManager.hide());
          } else if (_presentedNoticeKind != null) {
            _scheduleActionWindow();
          } else {
            _invalidateWindowPlacement();
          }
        },
        child: BlocBuilder<TextReplacementController, TextReplacementState>(
          builder: (context, state) {
            final strings = AppLocalizations.of(context)!;
            final child = switch (state.stage) {
              TextReplacementStage.capturing ||
              TextReplacementStage.copying ||
              TextReplacementStage.processing ||
              TextReplacementStage.validatingTarget ||
              TextReplacementStage.replacing ||
              TextReplacementStage.restoringClipboard =>
                const ProcessingStatusCard(key: ValueKey('processing')),
              TextReplacementStage.failed ||
              TextReplacementStage.completedWithWarning
                  when state.failureCode ==
                      'clipboard_recovery_manual_action_required' =>
                OverlayNotice(
                  key: const ValueKey('recovery'),
                  icon: LucideIcons.clipboardCheck,
                  title: strings.clipboardRecoveryTitle,
                  description: strings.clipboardRecoveryDescription,
                  primaryLabel: strings.retryClipboardRecovery,
                  onPrimary: () => context
                      .read<TextReplacementController>()
                      .retryClipboardRecovery(),
                  secondaryLabel: strings.dismiss,
                  onSecondary: _dismissWindow,
                ),
              TextReplacementStage.failed ||
              TextReplacementStage.completedWithWarning
                  when requiresClipboardStateReview(state.failureCode) =>
                OverlayNotice(
                  key: const ValueKey('clipboard-state-review'),
                  icon: LucideIcons.info,
                  title: strings.clipboardStateReviewTitle,
                  description: strings.clipboardStateReviewDescription,
                  secondaryLabel: strings.dismiss,
                  onSecondary: _dismissWindow,
                ),
              TextReplacementStage.failed
                  when requiresManualClipboardFallback(state.failureCode) =>
                OverlayNotice(
                  key: const ValueKey('clipboard-fallback'),
                  icon: LucideIcons.clipboard,
                  title: strings.clipboardFallbackTitle,
                  description: strings.clipboardFallbackDescription,
                  secondaryLabel: strings.dismiss,
                  onSecondary: _dismissWindow,
                ),
              TextReplacementStage.failed
                  when state.failureCode == 'transform_input_too_large' =>
                OverlayNotice(
                  key: const ValueKey('input-too-large'),
                  icon: LucideIcons.triangleAlert,
                  title: strings.processingInputTooLargeTitle,
                  description: strings.processingInputTooLargeDescription,
                  accentColor: AppColors.warning,
                  secondaryLabel: strings.dismiss,
                  onSecondary: _dismissWindow,
                ),
              TextReplacementStage.failed
                  when state.failureCode == 'transform_response_too_large' =>
                OverlayNotice(
                  key: const ValueKey('response-too-large'),
                  icon: LucideIcons.triangleAlert,
                  title: strings.processingResponseTooLargeTitle,
                  description: strings.processingResponseTooLargeDescription,
                  accentColor: AppColors.warning,
                  secondaryLabel: strings.dismiss,
                  onSecondary: _dismissWindow,
                ),
              TextReplacementStage.failed => OverlayNotice(
                  key: const ValueKey('failure'),
                  icon: LucideIcons.triangleAlert,
                  title: strings.processingError,
                  accentColor: AppColors.danger,
                  primaryLabel: state.action == null ? null : strings.retry,
                  onPrimary: state.action == null
                      ? null
                      : () => unawaited(
                            _retryAction(context, state.action!),
                          ),
                  secondaryLabel: strings.dismiss,
                  onSecondary: _dismissWindow,
                ),
              TextReplacementStage.completedWithWarning
                  when _isUnverifiedSuccess(state) =>
                const ReplacementSuccessCard(key: ValueKey('success')),
              TextReplacementStage.completedWithWarning => OverlayNotice(
                  key: const ValueKey('warning'),
                  icon: LucideIcons.info,
                  title: strings.processingWarningTitle,
                  description: strings.processingWarning,
                  accentColor: AppColors.warning,
                  secondaryLabel: strings.dismiss,
                  onSecondary: _dismissWindow,
                ),
              TextReplacementStage.awaitingManualPaste => OverlayNotice(
                  key: const ValueKey('manual-paste'),
                  icon: LucideIcons.clipboardPaste,
                  title: strings.manualPasteReadyTitle,
                  description: strings.manualPasteReadyDescription,
                  secondaryLabel: strings.dismiss,
                  onSecondary: _dismissWindow,
                ),
              _ => TextActionBar(
                  key: const ValueKey('actions'),
                  manualClipboardMode: context
                      .read<TextReplacementController>()
                      .requiresManualPaste,
                  onOpenSettings: widget.onOpenSettings,
                  processClipboardText: _processClipboardText,
                ),
            };
            final surface = AppSwap(
              child: SizedBox.expand(
                key: ValueKey<Key?>(child.key),
                child: child,
              ),
            );
            final exitDuration =
                AppMotion.resolve(context, AppMotion.overlayExit);
            final entrance = TweenAnimationBuilder<double>(
              key: ValueKey<int>(_entranceGeneration),
              tween: Tween<double>(begin: 0, end: 1),
              duration: AppMotion.resolve(context, AppMotion.overlayEnter),
              curve: AppMotion.enterCurve,
              builder: (context, value, animatedChild) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, 3 * (1 - value)),
                  child: Transform.scale(
                    scale: 0.98 + (0.02 * value),
                    child: animatedChild,
                  ),
                ),
              ),
              child: surface,
            );
            return AnimatedOpacity(
              opacity: _dismissing ? 0 : 1,
              duration: exitDuration,
              curve: AppMotion.exitCurve,
              child: AnimatedScale(
                scale: _dismissing ? 0.99 : 1,
                duration: exitDuration,
                curve: AppMotion.exitCurve,
                child: entrance,
              ),
            );
          },
        ),
      ),
    );
  }

  OverlayNoticeKind? _noticeKindForState(TextReplacementState state) {
    if (state.isBusy) {
      return OverlayNoticeKind.loading;
    }
    if (state.stage == TextReplacementStage.awaitingManualPaste) {
      return OverlayNoticeKind.manualPaste;
    }
    if (state.failureCode == 'clipboard_recovery_manual_action_required') {
      return OverlayNoticeKind.recovery;
    }
    if (requiresManualClipboardFallback(state.failureCode)) {
      return OverlayNoticeKind.clipboardFallback;
    }
    if (requiresClipboardStateReview(state.failureCode)) {
      return OverlayNoticeKind.clipboardStateReview;
    }
    if (state.failureCode == 'transform_input_too_large' ||
        state.failureCode == 'transform_response_too_large') {
      return OverlayNoticeKind.processingLimit;
    }
    if (state.stage == TextReplacementStage.failed) {
      return OverlayNoticeKind.failure;
    }
    if (state.stage == TextReplacementStage.completedWithWarning) {
      return _isUnverifiedSuccess(state)
          ? OverlayNoticeKind.success
          : OverlayNoticeKind.warning;
    }
    return null;
  }

  bool _isUnverifiedSuccess(TextReplacementState state) =>
      state.stage == TextReplacementStage.completedWithWarning &&
      state.failureCode == 'selection_commit_unverified';

  void _scheduleNoticeWindow(OverlayNoticeKind kind) {
    unawaited(
      _enqueueWindowPlacement(
        (generation) => _showNoticeWindow(kind, generation),
      ),
    );
  }

  void _scheduleActionWindow() {
    unawaited(
      _enqueueWindowPlacement((generation) async {
        if (!_placementIsCurrent(generation)) return;
        final controller = context.read<TextReplacementController>();
        final size = overlayWindowSizeFor(
          MediaQuery.maybeOf(context)?.textScaler ?? TextScaler.noScaling,
          manualClipboardMode: controller.requiresManualPaste,
        );
        final shown = await _placeWindowNearCursor(
          context.read<OverlayWindowGateway>(),
          size,
          generation,
        );
        if (shown) _presentedNoticeKind = null;
      }),
    );
  }

  Future<void> _showNoticeWindow(
    OverlayNoticeKind kind,
    int generation,
  ) async {
    final controller = context.read<TextReplacementController>();
    final gateway = context.read<OverlayWindowGateway>();
    if (!_placementIsCurrent(generation) ||
        _noticeKindForState(controller.state) != kind) {
      return;
    }
    // Busy stages emit several states that all map to the same notice kind
    // (loading). Re-running the whole native placement for each of them
    // (SetWindowPos + FRAMECHANGED + ShowWindow) makes the loading animation
    // stutter, so skip when this notice is already presented.
    if (_presentedNoticeKind == kind && _sessionShown) return;
    final desiredSize = noticeWindowSizeFor(
      MediaQuery.maybeOf(context)?.textScaler ?? TextScaler.noScaling,
      kind: kind,
    );
    final shown = await _placeWindowNearCursor(
      gateway,
      desiredSize,
      generation,
    );
    if (shown &&
        _placementIsCurrent(generation) &&
        _noticeKindForState(controller.state) == kind) {
      _presentedNoticeKind = kind;
    }
  }

  Future<bool> _placeWindowNearCursor(
    OverlayWindowGateway gateway,
    Size desiredSize,
    int generation,
  ) async {
    final anchor = _sessionAnchor ?? await resolveOverlayAnchorPoint(gateway);
    if (!_placementIsCurrent(generation)) return false;
    _sessionAnchor = anchor;
    final freshPresentation = !_sessionShown;

    await windowManager.setMinimumSize(const Size(1, 1));
    if (!_placementIsCurrent(generation)) return false;

    Size fittedSize;
    int? nativeWindowHandle;
    if (gateway case final NativeOverlayPlacementGateway nativePlacement) {
      final placement = await nativePlacement.resolveOverlayPlacement(
        point: anchor,
        desiredLogicalSize: desiredSize,
      );
      if (!_placementIsCurrent(generation)) return false;
      final previousBounds = _lastNativeBounds;
      // Only animate pure moves: every animation step that changes the window
      // size forces a synchronous swapchain resize, which visibly stutters
      // any in-flight content animation (e.g. the processing indicator).
      final isPureMove = previousBounds != null &&
          previousBounds != placement.nativeBounds &&
          (previousBounds.width - placement.nativeBounds.width).abs() < 1 &&
          (previousBounds.height - placement.nativeBounds.height).abs() < 1;
      if (!freshPresentation && isPureMove) {
        await _animateNativeBounds(
          nativePlacement,
          placement,
          from: previousBounds,
          generation: generation,
        );
        if (!_placementIsCurrent(generation)) return false;
      } else {
        nativePlacement.applyOverlayPlacement(placement);
      }
      _lastNativeBounds = placement.nativeBounds;
      fittedSize = placement.logicalSize;
      nativeWindowHandle = placement.nativeWindowHandle;
    } else {
      final workArea = await gateway.getWorkAreaForPoint(anchor);
      if (!_placementIsCurrent(generation)) return false;
      fittedSize = fitWindowSizeToWorkArea(desiredSize, workArea);
      final position = positionOverlayNearCursor(
        cursor: anchor,
        overlaySize: fittedSize,
        workArea: workArea,
      );
      await windowManager.setBounds(
        Rect.fromLTWH(
          position.dx,
          position.dy,
          fittedSize.width,
          fittedSize.height,
        ),
      );
    }
    if (!_placementIsCurrent(generation)) return false;
    await windowManager.setMinimumSize(fittedSize);
    if (!_placementIsCurrent(generation)) return false;
    if (freshPresentation) _replayEntrance();
    await settleFrame();
    if (!_placementIsCurrent(generation)) return false;
    if (gateway case final NativeOwnedOverlayActivationGateway activation) {
      await activation.showOwnedWindowInactive();
    } else if (gateway case final NativeOverlayActivationGateway activation
        when nativeWindowHandle != null) {
      activation.setWindowCanActivate(nativeWindowHandle, false);
      activation.showWindowInactive(nativeWindowHandle);
    } else {
      await windowManager.show(inactive: true);
    }
    if (_placementIsCurrent(generation)) {
      _sessionShown = true;
      unawaited(widget.interaction.watchOutsideClick(true));
      return true;
    }
    return false;
  }

  Future<void> _animateNativeBounds(
    NativeOverlayPlacementGateway gateway,
    NativeOverlayPlacement target, {
    required Rect from,
    required int generation,
  }) async {
    final stepDelay = Duration(
      microseconds: _resizeDuration.inMicroseconds ~/ _resizeSteps,
    );
    for (var step = 1; step <= _resizeSteps; step++) {
      final progress = Curves.easeOutCubic.transform(step / _resizeSteps);
      gateway.applyOverlayPlacement(
        NativeOverlayPlacement(
          nativeWindowHandle: target.nativeWindowHandle,
          nativeBounds: Rect.lerp(from, target.nativeBounds, progress)!,
          logicalSize: target.logicalSize,
        ),
      );
      if (step < _resizeSteps) {
        await Future<void>.delayed(stepDelay);
        if (!_placementIsCurrent(generation)) return;
      }
    }
  }

  Future<void> _enqueueWindowPlacement(
    Future<void> Function(int generation) operation,
  ) {
    final generation = ++_windowPlacementGeneration;
    final result = _windowPlacementTail.then(
      (_) => operation(generation),
    );
    _windowPlacementTail = result.then<void>(
      (_) {},
      onError: (_, __) {},
    );
    return result;
  }

  bool _placementIsCurrent(int generation) =>
      mounted && generation == _windowPlacementGeneration;

  void _invalidateWindowPlacement() {
    _windowPlacementGeneration++;
  }

  Future<void> _activateVisibleOverlayShortcut(
    TextReplacementController controller,
  ) async {
    if (controller.state.failureCode ==
        'clipboard_recovery_manual_action_required') {
      await controller.retryClipboardRecovery();
      return;
    }
    final action = controller.state.action;
    if (controller.state.stage == TextReplacementStage.failed &&
        action != null) {
      await _retryAction(context, action);
      return;
    }
    await _dismissWindow();
  }

  bool _canResetTerminalState(TextReplacementState state) {
    if (state.failureCode == 'clipboard_recovery_manual_action_required') {
      return false;
    }
    return state.stage == TextReplacementStage.failed ||
        state.stage == TextReplacementStage.completedWithWarning ||
        state.stage == TextReplacementStage.cancelled;
  }

  Future<void> _dismissWindow() async {
    if (_dismissing) return;
    _invalidateWindowPlacement();
    _presentedNoticeKind = null;
    _resetSession();
    final controller = context.read<TextReplacementController>();
    final manualPaste = controller.requiresManualPaste;
    setState(() => _dismissing = true);
    final duration = AppMotion.resolve(context, AppMotion.overlayExit);
    if (duration != Duration.zero) await Future<void>.delayed(duration);
    if (_canResetTerminalState(controller.state) ||
        controller.state.stage == TextReplacementStage.awaitingManualPaste) {
      controller.reset();
    }
    if (manualPaste) {
      await windowManager.minimize();
    } else {
      await windowManager.hide();
    }
    _releasePermit();
    if (mounted) setState(() => _dismissing = false);
  }

  Future<void> _retryAction(BuildContext context, TextAction action) async {
    final controller = context.read<TextReplacementController>();
    if (controller.state.isBusy) return;
    final permit = context.read<TextOperationGate>().tryAcquire();
    if (permit == null) return;
    _permit = permit;
    controller.reset();
    await _processClipboardText(context, action);
  }
}

class OverlayNotice extends StatelessWidget {
  const OverlayNotice({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.primaryLabel,
    this.onPrimary,
    this.accentColor,
    required this.secondaryLabel,
    required this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String? description;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final Color? accentColor;
  final String secondaryLabel;
  final VoidCallback onSecondary;

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? AppColors.brand;
    final compact = description == null;
    final iconTile = SizedBox.square(
      dimension: compact ? 34 : 40,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Center(
            child: Icon(icon, size: compact ? 17 : 20, color: accent),
          ),
        ),
      ),
    );
    return Semantics(
      key: const ValueKey('overlay-notice-semantics'),
      container: true,
      explicitChildNodes: true,
      liveRegion: true,
      label: description == null ? title : '$title. $description',
      hint: AppLocalizations.of(context)?.overlayShortcutHint,
      child: AppOverlaySurface(
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
            : const EdgeInsets.all(AppSpacing.md),
        child: SingleChildScrollView(
          child: compact
              ? Row(
                  children: [
                    iconTile,
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: ExcludeSemantics(
                        child: Text(
                          title,
                          style: AppTextStyles.label(context),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (primaryLabel != null && onPrimary != null) ...[
                      const SizedBox(width: AppSpacing.xs),
                      AppButton(
                        label: primaryLabel!,
                        onPressed: onPrimary,
                        autofocus: true,
                        compact: true,
                        kind: AppButtonKind.primary,
                      ),
                    ],
                    const SizedBox(width: AppSpacing.xxs),
                    AppIconButton(
                      icon: LucideIcons.x,
                      label: secondaryLabel,
                      onPressed: onSecondary,
                      size: 16,
                    ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    iconTile,
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ExcludeSemantics(
                            child: Text(
                              title,
                              style: AppTextStyles.title(context),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          ExcludeSemantics(
                            child: Text(
                              description!,
                              style: TextStyle(
                                color: AppColors.textSecondary(context),
                              ),
                            ),
                          ),
                          if (primaryLabel != null && onPrimary != null) ...[
                            const SizedBox(height: AppSpacing.sm),
                            AppButton(
                              label: primaryLabel!,
                              onPressed: onPrimary,
                              autofocus: true,
                              kind: AppButtonKind.primary,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    AppIconButton(
                      icon: LucideIcons.x,
                      label: secondaryLabel,
                      onPressed: onSecondary,
                      autofocus: primaryLabel == null || onPrimary == null,
                      size: 16,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
