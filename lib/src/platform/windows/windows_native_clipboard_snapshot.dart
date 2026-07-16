import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_platform_gateway.dart';

const _success = 0;
const _revisionConflict = 1;
const _clipboardOpenFailed = 2;
const _unsupportedFormat = 3;
const _snapshotTooLarge = 4;
const _allocationFailed = 5;
const _clipboardMutationFailed = 6;
const _snapshotNotFound = 7;
const _clipboardChangedDuringCapture = 8;
const _rollbackFailed = 9;
const _brokerTimeout = 10;
const windowsNativeClipboardProbeArgument =
    '--yandex-keyboard-native-clipboard-probe';

bool runWindowsNativeClipboardProbeIfRequested(List<String> arguments) {
  if (!Platform.isWindows ||
      arguments.length != 1 ||
      arguments.single != windowsNativeClipboardProbeArgument) {
    return false;
  }
  exit(WindowsNativeClipboardSnapshotBridge().probeAbi() ? 0 : 78);
}

final class WindowsNativeClipboardCapture {
  const WindowsNativeClipboardCapture({
    required this.status,
    required this.token,
    required this.revision,
  });

  final int status;
  final int token;
  final int revision;
}

final class WindowsNativeClipboardRestore {
  const WindowsNativeClipboardRestore({
    required this.status,
    required this.revision,
  });

  final int status;
  final int revision;
}

abstract interface class WindowsNativeClipboardApi {
  bool get isAvailable;

  WindowsNativeClipboardCapture capture({
    required int ownerWindow,
    required int maximumBytes,
  });

  WindowsNativeClipboardRestore restore({
    required int ownerWindow,
    required int token,
    required int expectedRevision,
    required String rollbackText,
  });

  int release(int token);

  bool probeAbi();
}

final class WindowsNativeClipboardSnapshotBridge {
  WindowsNativeClipboardSnapshotBridge({
    WindowsNativeClipboardApi? api,
    this.maximumSnapshotBytes = 64 * 1024 * 1024,
  })  : assert(maximumSnapshotBytes > 0),
        _api = api ?? _Win32NativeClipboardApi.load();

  final WindowsNativeClipboardApi _api;
  final int maximumSnapshotBytes;

  bool get isAvailable => _api.isAvailable;

  bool probeAbi() => _api.isAvailable && _api.probeAbi();

  PlatformClipboardSnapshot capture({required int ownerWindow}) {
    if (!_api.isAvailable || ownerWindow == 0) {
      throw const ClipboardTransactionException(
        code: 'windows_clipboard_snapshot_unavailable',
        retryable: false,
      );
    }
    final result = _api.capture(
      ownerWindow: ownerWindow,
      maximumBytes: maximumSnapshotBytes,
    );
    if (result.status != _success) {
      throw _captureFailure(result.status);
    }
    if (result.token <= 0 || result.revision < 0) {
      throw const ClipboardTransactionException(
        code: 'windows_clipboard_snapshot_invalid_result',
        retryable: false,
      );
    }
    return PlatformClipboardSnapshot(
      revision: result.revision,
      payload: result.token,
    );
  }

  int? restore(
    Object payload, {
    required int ownerWindow,
    required int expectedRevision,
    required String rollbackText,
  }) {
    if (!_api.isAvailable ||
        ownerWindow == 0 ||
        payload is! int ||
        payload <= 0) {
      throw const ClipboardTransactionException(
        code: 'windows_clipboard_snapshot_token_invalid',
        retryable: false,
      );
    }
    final result = _api.restore(
      ownerWindow: ownerWindow,
      token: payload,
      expectedRevision: expectedRevision,
      rollbackText: rollbackText,
    );
    if (result.status == _success) return result.revision;
    if (result.status == _revisionConflict) return null;
    if (result.status == _clipboardMutationFailed) {
      throw AtomicClipboardMutationException(
        revision: result.revision,
        currentText: rollbackText,
      );
    }
    if (result.status == _rollbackFailed || result.status == _brokerTimeout) {
      throw UnknownClipboardMutationException(
        code: result.status == _rollbackFailed
            ? 'windows_clipboard_snapshot_rollback_failed'
            : 'windows_clipboard_snapshot_restore_timeout',
        revision: result.revision,
      );
    }
    throw _restoreFailure(result.status);
  }

  void release(Object payload) {
    if (payload is! int || payload <= 0) return;
    final status = _api.release(payload);
    if (status != _success) {
      throw ClipboardTransactionException(
        code: status == _snapshotNotFound
            ? 'windows_clipboard_snapshot_not_found'
            : 'windows_clipboard_snapshot_release_failed',
        retryable: false,
      );
    }
  }

  ClipboardTransactionException _captureFailure(int status) => switch (status) {
        _clipboardOpenFailed => const ClipboardTransactionException(
            code: 'windows_clipboard_open_failed',
            retryable: true,
          ),
        _unsupportedFormat => const ClipboardTransactionException(
            code: 'windows_clipboard_snapshot_format_unsupported',
            retryable: false,
          ),
        _snapshotTooLarge => const ClipboardTransactionException(
            code: 'windows_clipboard_snapshot_too_large',
            retryable: false,
          ),
        _allocationFailed => const ClipboardTransactionException(
            code: 'windows_clipboard_snapshot_allocation_failed',
            retryable: false,
          ),
        _clipboardChangedDuringCapture => const ClipboardTransactionException(
            code: 'windows_clipboard_snapshot_unstable',
            retryable: true,
          ),
        _brokerTimeout => const ClipboardTransactionException(
            code: 'windows_clipboard_snapshot_capture_timeout',
            retryable: true,
          ),
        _ => const ClipboardTransactionException(
            code: 'windows_clipboard_snapshot_failed',
            retryable: false,
          ),
      };

  ClipboardTransactionException _restoreFailure(int status) => switch (status) {
        _clipboardOpenFailed => const ClipboardTransactionException(
            code: 'windows_clipboard_open_failed',
            retryable: true,
          ),
        _snapshotNotFound => const ClipboardTransactionException(
            code: 'windows_clipboard_snapshot_not_found',
            retryable: false,
          ),
        _allocationFailed => const ClipboardTransactionException(
            code: 'windows_clipboard_snapshot_allocation_failed',
            retryable: false,
          ),
        _unsupportedFormat => const ClipboardTransactionException(
            code: 'windows_clipboard_snapshot_format_unsupported',
            retryable: false,
          ),
        _snapshotTooLarge => const ClipboardTransactionException(
            code: 'windows_clipboard_snapshot_too_large',
            retryable: false,
          ),
        _ => const ClipboardTransactionException(
            code: 'windows_clipboard_snapshot_restore_failed',
            retryable: false,
          ),
      };
}

// coverage:ignore-start
typedef _CaptureNative = Int32 Function(
  IntPtr ownerWindow,
  Uint64 maximumBytes,
  Pointer<Uint64> snapshotToken,
  Pointer<Uint32> capturedRevision,
);
typedef _CaptureDart = int Function(
  int ownerWindow,
  int maximumBytes,
  Pointer<Uint64> snapshotToken,
  Pointer<Uint32> capturedRevision,
);
typedef _RestoreNative = Int32 Function(
  IntPtr ownerWindow,
  Uint64 snapshotToken,
  Uint32 expectedRevision,
  Pointer<Utf16> rollbackText,
  Pointer<Uint32> resultingRevision,
);
typedef _RestoreDart = int Function(
  int ownerWindow,
  int snapshotToken,
  int expectedRevision,
  Pointer<Utf16> rollbackText,
  Pointer<Uint32> resultingRevision,
);
typedef _ReleaseNative = Int32 Function(Uint64 snapshotToken);
typedef _ReleaseDart = int Function(int snapshotToken);

final class _Win32NativeClipboardApi implements WindowsNativeClipboardApi {
  const _Win32NativeClipboardApi._({
    required _CaptureDart? capture,
    required _RestoreDart? restore,
    required _ReleaseDart? release,
  })  : _capture = capture,
        _restore = restore,
        _release = release;

  factory _Win32NativeClipboardApi.load() {
    if (!Platform.isWindows) {
      return const _Win32NativeClipboardApi._(
        capture: null,
        restore: null,
        release: null,
      );
    }
    try {
      final library = DynamicLibrary.executable();
      return _Win32NativeClipboardApi._(
        capture: library.lookupFunction<_CaptureNative, _CaptureDart>(
          'YkdCaptureClipboardSnapshot',
        ),
        restore: library.lookupFunction<_RestoreNative, _RestoreDart>(
          'YkdRestoreClipboardSnapshotIfRevision',
        ),
        release: library.lookupFunction<_ReleaseNative, _ReleaseDart>(
          'YkdReleaseClipboardSnapshot',
        ),
      );
    } on ArgumentError {
      return const _Win32NativeClipboardApi._(
        capture: null,
        restore: null,
        release: null,
      );
    }
  }

  final _CaptureDart? _capture;
  final _RestoreDart? _restore;
  final _ReleaseDart? _release;

  @override
  bool get isAvailable =>
      _capture != null && _restore != null && _release != null;

  @override
  WindowsNativeClipboardCapture capture({
    required int ownerWindow,
    required int maximumBytes,
  }) {
    final capture = _capture;
    if (capture == null) {
      return const WindowsNativeClipboardCapture(
        status: _unsupportedFormat,
        token: 0,
        revision: 0,
      );
    }
    final token = calloc<Uint64>();
    final revision = calloc<Uint32>();
    try {
      final status = capture(ownerWindow, maximumBytes, token, revision);
      return WindowsNativeClipboardCapture(
        status: status,
        token: token.value,
        revision: revision.value,
      );
    } finally {
      calloc
        ..free(token)
        ..free(revision);
    }
  }

  @override
  WindowsNativeClipboardRestore restore({
    required int ownerWindow,
    required int token,
    required int expectedRevision,
    required String rollbackText,
  }) {
    final restore = _restore;
    if (restore == null) {
      return const WindowsNativeClipboardRestore(
        status: _snapshotNotFound,
        revision: 0,
      );
    }
    final rollback = rollbackText.toNativeUtf16();
    final revision = calloc<Uint32>();
    try {
      final status = restore(
        ownerWindow,
        token,
        expectedRevision,
        rollback,
        revision,
      );
      return WindowsNativeClipboardRestore(
        status: status,
        revision: revision.value,
      );
    } finally {
      calloc
        ..free(rollback)
        ..free(revision);
    }
  }

  @override
  int release(int token) => _release?.call(token) ?? _snapshotNotFound;

  @override
  bool probeAbi() {
    final capture = _capture;
    final restore = _restore;
    final release = _release;
    if (capture == null || restore == null || release == null) return false;
    final token = calloc<Uint64>();
    final revision = calloc<Uint32>();
    final rollback = ''.toNativeUtf16();
    try {
      final captureStatus = capture(0, 0, token, revision);
      final captureOutputsValid = token.value == 0 && revision.value == 0;
      revision.value = 0;
      final restoreStatus = restore(0, 0, 0, rollback, revision);
      final releaseStatus = release(0);
      return captureStatus == _allocationFailed &&
          captureOutputsValid &&
          restoreStatus == _snapshotNotFound &&
          releaseStatus == _success;
    } finally {
      calloc
        ..free(token)
        ..free(revision)
        ..free(rollback);
    }
  }
}
// coverage:ignore-end
