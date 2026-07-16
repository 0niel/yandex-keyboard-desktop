import 'dart:async';

import 'package:flutter/painting.dart' as painting;
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:yandex_keyboard_desktop/src/platform/linux/linux_native_bridge.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_platform_gateway.dart';

abstract interface class LinuxClipboardGateway {
  Future<String> readText();
}

final class FlutterLinuxClipboardGateway implements LinuxClipboardGateway {
  const FlutterLinuxClipboardGateway();

  @override
  Future<String> readText() async {
    return (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
  }
}

class LinuxPlatformGateway
    implements
        SelectionPlatformGateway,
        OverlayWindowGateway,
        NativeOwnedOverlayActivationGateway,
        NativeClipboardSnapshotGateway,
        StableClipboardTextGateway {
  LinuxPlatformGateway({
    LinuxNativeBridge bridge = const MethodChannelLinuxNativeBridge(),
    LinuxClipboardGateway clipboard = const FlutterLinuxClipboardGateway(),
    this.copySettleDelay = const Duration(milliseconds: 100),
    this.focusSettleDelay = const Duration(milliseconds: 40),
  })  : _bridge = bridge,
        _clipboard = clipboard;

  final LinuxNativeBridge _bridge;
  final LinuxClipboardGateway _clipboard;
  final Duration copySettleDelay;
  final Duration focusSettleDelay;
  int _originalWindowHandle = 0;
  Future<LinuxNativeCapabilities>? _capabilities;
  LinuxNativeCapabilities? _resolvedCapabilities;

  static const maxClipboardSnapshotBytes = 8 * 1024 * 1024;
  static const maxClipboardSnapshotTargets = 64;
  static const clipboardTransferTimeoutMilliseconds = 1000;

  Future<LinuxNativeCapabilities> get capabilities =>
      _capabilities ??= _bridge.getCapabilities().then((value) {
        _resolvedCapabilities = value;
        return value;
      });

  Future<bool> supportsAutomaticSelectionReplacement() async {
    try {
      final current = await capabilities;
      return current.targetWindows &&
          current.inputInjection &&
          current.clipboardRevision &&
          current.clipboardOwnership &&
          _supportsSafeClipboardTransaction(current);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> getSelectedText(int targetHandle) async {
    final current = await capabilities;
    if (!current.inputInjection) {
      throw UnsupportedError('linux_input_injection_unavailable');
    }
    await _bridge.injectCopy(targetHandle);
    await Future<void>.delayed(copySettleDelay);
    return _clipboard.readText();
  }

  @override
  Future<painting.Size> getScreenSize() async {
    final primaryScreen = await screenRetriever.getPrimaryDisplay();
    return painting.Size(primaryScreen.size.width, primaryScreen.size.height);
  }

  @override
  Future<painting.Rect> getWorkAreaForPoint(Offset point) async {
    final displays = await screenRetriever.getAllDisplays();
    return nearestWorkArea(
      point,
      displays.map((display) {
        final origin = display.visiblePosition ?? Offset.zero;
        final size = display.visibleSize ?? display.size;
        return origin & size;
      }),
    );
  }

  @override
  Future<Offset> getCursorPos() async {
    final cursorOffset = await screenRetriever.getCursorScreenPoint();
    return cursorOffset;
  }

  @override
  Future<void> replaceSelectedText(int targetHandle, String newText) async {
    final current = await capabilities;
    if (!current.inputInjection) {
      throw UnsupportedError('linux_input_injection_unavailable');
    }
    await _bridge.injectPaste(targetHandle);
  }

  @override
  int getOriginalForegroundWindow() => _originalWindowHandle;

  @override
  Future<int> getClipboardRevision() => _bridge.getClipboardRevision();

  @override
  Future<bool> isWindowValid(int handle) => _bridge.isWindowValid(handle);

  @override
  Future<bool> focusWindow(int handle) async {
    if (!await _bridge.focusWindow(handle)) return false;
    await Future<void>.delayed(focusSettleDelay);
    return await _bridge.getForegroundWindow() == handle;
  }

  @override
  Future<bool> supportsLosslessTextClipboardSnapshot() async =>
      _supportsSafeClipboardTransaction(await capabilities);

  @override
  Future<bool> isClipboardOwnedByTarget(int handle) =>
      _bridge.isClipboardOwnedByTarget(handle);

  @override
  bool supportsAtomicTextClipboardTransactions() {
    final current = _resolvedCapabilities;
    return current != null && _supportsSafeClipboardTransaction(current);
  }

  @override
  Future<int?> writeClipboardTextIfRevision(
    String text, {
    required int expectedRevision,
    required String rollbackText,
  }) =>
      _mapClipboardMutation(() => _bridge.writeClipboardTextIfRevision(
            text,
            expectedRevision: expectedRevision,
            rollbackText: rollbackText,
          ));

  @override
  Future<bool> supportsNativeClipboardSnapshots() async => _mapClipboardCapture(
        () async => _supportsSafeClipboardTransaction(await capabilities),
      );

  @override
  Future<PlatformClipboardSnapshot> captureNativeClipboardSnapshot() =>
      _mapClipboardCapture(() => _bridge.captureNativeClipboardSnapshot(
            maxBytes: maxClipboardSnapshotBytes,
            maxTargets: maxClipboardSnapshotTargets,
            timeoutMilliseconds: clipboardTransferTimeoutMilliseconds,
          ));

  @override
  Future<int?> restoreNativeClipboardSnapshotIfRevision(
    Object payload, {
    required int expectedRevision,
    required String rollbackText,
  }) =>
      _mapClipboardMutation(
        () => _bridge.restoreNativeClipboardSnapshotIfRevision(
          payload,
          expectedRevision: expectedRevision,
          rollbackText: rollbackText,
        ),
      );

  @override
  Future<void> releaseNativeClipboardSnapshot(Object payload) =>
      _bridge.releaseNativeClipboardSnapshot(payload);

  @override
  Future<bool> supportsStableClipboardTextReads() async => _mapClipboardCapture(
        () async => _supportsSafeClipboardTransaction(await capabilities),
      );

  bool _supportsSafeClipboardTransaction(LinuxNativeCapabilities current) =>
      current.losslessTextClipboardSnapshot &&
      current.nativeClipboardSnapshots &&
      current.stableClipboardReads &&
      current.atomicClipboardTransactions;

  @override
  Future<StableClipboardTextRead> copySelectionTextWithEvidence(
    int targetHandle,
  ) =>
      _mapClipboardCapture(() => _bridge.copySelectionTextWithEvidence(
            targetHandle,
            maxBytes: maxClipboardSnapshotBytes,
            maxTargets: maxClipboardSnapshotTargets,
            timeoutMilliseconds: clipboardTransferTimeoutMilliseconds,
          ));

  Future<T> _mapClipboardCapture<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PlatformException catch (error) {
      throw ClipboardTransactionException(
        code: error.code,
        retryable: _isRetryableClipboardError(error),
      );
    } on FormatException {
      throw const ClipboardTransactionException(
        code: 'linux_native_clipboard_response_invalid',
        retryable: false,
      );
    }
  }

  Future<int?> _mapClipboardMutation(
    Future<int?> Function() operation,
  ) async {
    try {
      return await operation();
    } on PlatformException catch (error) {
      final details = error.details;
      if (error.code == 'linux_clipboard_mutated' &&
          details is Map<Object?, Object?> &&
          details['revision'] is int &&
          details['currentText'] is String) {
        throw AtomicClipboardMutationException(
          revision: details['revision']! as int,
          currentText: details['currentText']! as String,
        );
      }
      throw ClipboardTransactionException(
        code: error.code,
        retryable: _isRetryableClipboardError(error),
      );
    } on FormatException {
      throw const ClipboardTransactionException(
        code: 'linux_native_clipboard_response_invalid',
        retryable: false,
      );
    }
  }

  bool _isRetryableClipboardError(PlatformException error) {
    final details = error.details;
    return details is Map<Object?, Object?> && details['retryable'] == true;
  }

  @override
  Future<int> getForegroundWindow() => _bridge.getForegroundWindow();

  @override
  Future<int> getWindowProcessId(int handle) =>
      _bridge.getWindowProcessId(handle);

  @override
  void setOriginalForegroundWindow(int handle) {
    _originalWindowHandle = handle;
  }

  @override
  Future<int> getFlutterWindowHandle() => _bridge.getFlutterWindowHandle();

  @override
  Future<void> setOwnedWindowCanActivate(bool canActivate) =>
      _bridge.setApplicationWindowCanActivate(canActivate);

  @override
  Future<void> showOwnedWindowInactive() =>
      _bridge.showApplicationWindowInactive();
}
