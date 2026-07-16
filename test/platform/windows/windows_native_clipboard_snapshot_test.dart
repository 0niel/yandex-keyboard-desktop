import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_platform_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/windows_native_clipboard_snapshot.dart';

void main() {
  test('captures only an opaque token and native revision', () {
    final api = _FakeWindowsNativeClipboardApi()
      ..captureResult = const WindowsNativeClipboardCapture(
        status: 0,
        token: 41,
        revision: 73,
      );
    final bridge = WindowsNativeClipboardSnapshotBridge(api: api);

    final snapshot = bridge.capture(ownerWindow: 11);

    expect(snapshot.revision, 73);
    expect(snapshot.payload, 41);
    expect(api.lastOwnerWindow, 11);
    expect(api.lastMaximumBytes, 64 * 1024 * 1024);
  });

  test('rejects capture when native exports are unavailable', () {
    final bridge = WindowsNativeClipboardSnapshotBridge(
      api: _FakeWindowsNativeClipboardApi(isAvailable: false),
    );

    expect(
      () => bridge.capture(ownerWindow: 11),
      throwsA(
        isA<ClipboardTransactionException>()
            .having(
              (error) => error.code,
              'code',
              'windows_clipboard_snapshot_unavailable',
            )
            .having((error) => error.retryable, 'retryable', isFalse),
      ),
    );
  });

  test('maps size limits and unstable capture to typed failures', () {
    final api = _FakeWindowsNativeClipboardApi();
    final bridge = WindowsNativeClipboardSnapshotBridge(api: api);

    api.captureResult = const WindowsNativeClipboardCapture(
      status: 4,
      token: 0,
      revision: 0,
    );
    expect(
      () => bridge.capture(ownerWindow: 11),
      throwsA(
        isA<ClipboardTransactionException>().having(
          (error) => error.code,
          'code',
          'windows_clipboard_snapshot_too_large',
        ),
      ),
    );

    api.captureResult = const WindowsNativeClipboardCapture(
      status: 8,
      token: 0,
      revision: 0,
    );
    expect(
      () => bridge.capture(ownerWindow: 11),
      throwsA(
        isA<ClipboardTransactionException>()
            .having(
              (error) => error.code,
              'code',
              'windows_clipboard_snapshot_unstable',
            )
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('returns null without mutation when the clipboard revision changed', () {
    final api = _FakeWindowsNativeClipboardApi()
      ..restoreResult = const WindowsNativeClipboardRestore(
        status: 1,
        revision: 74,
      );
    final bridge = WindowsNativeClipboardSnapshotBridge(api: api);

    expect(
      bridge.restore(
        41,
        ownerWindow: 11,
        expectedRevision: 73,
        rollbackText: 'staged',
      ),
      isNull,
    );
    expect(api.lastExpectedRevision, 73);
    expect(api.lastRollbackText, 'staged');
  });

  test('reports an acquired revision after a partial native mutation', () {
    final api = _FakeWindowsNativeClipboardApi()
      ..restoreResult = const WindowsNativeClipboardRestore(
        status: 6,
        revision: 75,
      );
    final bridge = WindowsNativeClipboardSnapshotBridge(api: api);

    expect(
      () => bridge.restore(
        41,
        ownerWindow: 11,
        expectedRevision: 73,
        rollbackText: 'staged',
      ),
      throwsA(
        isA<AtomicClipboardMutationException>()
            .having((error) => error.revision, 'revision', 75)
            .having((error) => error.currentText, 'currentText', 'staged'),
      ),
    );
  });

  test('never claims rollback text when native clipboard state is unknown', () {
    final api = _FakeWindowsNativeClipboardApi()
      ..restoreResult = const WindowsNativeClipboardRestore(
        status: 9,
        revision: 76,
      );
    final bridge = WindowsNativeClipboardSnapshotBridge(api: api);

    expect(
      () => bridge.restore(
        41,
        ownerWindow: 11,
        expectedRevision: 73,
        rollbackText: 'must-not-be-claimed',
      ),
      throwsA(
        isA<UnknownClipboardMutationException>()
            .having((error) => error.revision, 'revision', 76)
            .having(
              (error) => error.code,
              'code',
              'windows_clipboard_snapshot_rollback_failed',
            ),
      ),
    );
  });

  test('release is idempotent for malformed Dart payloads', () {
    final api = _FakeWindowsNativeClipboardApi();
    final bridge = WindowsNativeClipboardSnapshotBridge(api: api);

    bridge
      ..release('not-a-token')
      ..release(0)
      ..release(41);

    expect(api.releasedTokens, <int>[41]);
  });

  test('capture maps every native failure family without clipboard data', () {
    final api = _FakeWindowsNativeClipboardApi();
    final bridge = WindowsNativeClipboardSnapshotBridge(api: api);
    const cases = <int, (String, bool)>{
      2: ('windows_clipboard_open_failed', true),
      3: ('windows_clipboard_snapshot_format_unsupported', false),
      4: ('windows_clipboard_snapshot_too_large', false),
      5: ('windows_clipboard_snapshot_allocation_failed', false),
      8: ('windows_clipboard_snapshot_unstable', true),
      10: ('windows_clipboard_snapshot_capture_timeout', true),
      99: ('windows_clipboard_snapshot_failed', false),
    };

    for (final entry in cases.entries) {
      api.captureResult = WindowsNativeClipboardCapture(
        status: entry.key,
        token: 0,
        revision: 0,
      );
      expect(
        () => bridge.capture(ownerWindow: 11),
        throwsA(
          isA<ClipboardTransactionException>()
              .having((error) => error.code, 'code', entry.value.$1)
              .having(
                (error) => error.retryable,
                'retryable',
                entry.value.$2,
              ),
        ),
      );
    }
  });

  test('capture validates native success tokens', () {
    final api = _FakeWindowsNativeClipboardApi()
      ..captureResult = const WindowsNativeClipboardCapture(
        status: 0,
        token: 0,
        revision: 8,
      );
    final bridge = WindowsNativeClipboardSnapshotBridge(api: api);

    expect(
      () => bridge.capture(ownerWindow: 11),
      throwsA(
        isA<ClipboardTransactionException>().having(
          (error) => error.code,
          'code',
          'windows_clipboard_snapshot_invalid_result',
        ),
      ),
    );
  });

  test('restore maps success, invalid tokens, and native failures', () {
    final api = _FakeWindowsNativeClipboardApi();
    final bridge = WindowsNativeClipboardSnapshotBridge(api: api);

    expect(
      bridge.restore(
        41,
        ownerWindow: 11,
        expectedRevision: 73,
        rollbackText: 'staged',
      ),
      2,
    );
    expect(
      () => bridge.restore(
        'invalid',
        ownerWindow: 11,
        expectedRevision: 73,
        rollbackText: 'staged',
      ),
      throwsA(
        isA<ClipboardTransactionException>().having(
          (error) => error.code,
          'code',
          'windows_clipboard_snapshot_token_invalid',
        ),
      ),
    );

    const cases = <int, (String, bool)>{
      2: ('windows_clipboard_open_failed', true),
      3: ('windows_clipboard_snapshot_format_unsupported', false),
      4: ('windows_clipboard_snapshot_too_large', false),
      5: ('windows_clipboard_snapshot_allocation_failed', false),
      7: ('windows_clipboard_snapshot_not_found', false),
      8: ('windows_clipboard_snapshot_restore_failed', false),
    };
    for (final entry in cases.entries) {
      api.restoreResult = WindowsNativeClipboardRestore(
        status: entry.key,
        revision: 74,
      );
      expect(
        () => bridge.restore(
          41,
          ownerWindow: 11,
          expectedRevision: 73,
          rollbackText: 'staged',
        ),
        throwsA(
          isA<ClipboardTransactionException>()
              .having((error) => error.code, 'code', entry.value.$1)
              .having(
                (error) => error.retryable,
                'retryable',
                entry.value.$2,
              ),
        ),
      );
    }
  });

  test('release exposes native lifecycle failure and probe ignores other args',
      () {
    final api = _FakeWindowsNativeClipboardApi()..releaseStatus = 7;
    final bridge = WindowsNativeClipboardSnapshotBridge(api: api);

    expect(
      () => bridge.release(41),
      throwsA(
        isA<ClipboardTransactionException>().having(
          (error) => error.code,
          'code',
          'windows_clipboard_snapshot_not_found',
        ),
      ),
    );
    expect(
        runWindowsNativeClipboardProbeIfRequested(const <String>[]), isFalse);
    expect(
      runWindowsNativeClipboardProbeIfRequested(const <String>['other']),
      isFalse,
    );
  });
}

final class _FakeWindowsNativeClipboardApi
    implements WindowsNativeClipboardApi {
  _FakeWindowsNativeClipboardApi({this.isAvailable = true});

  @override
  final bool isAvailable;

  WindowsNativeClipboardCapture captureResult =
      const WindowsNativeClipboardCapture(
    status: 0,
    token: 1,
    revision: 1,
  );
  WindowsNativeClipboardRestore restoreResult =
      const WindowsNativeClipboardRestore(status: 0, revision: 2);
  int releaseStatus = 0;
  int? lastOwnerWindow;
  int? lastMaximumBytes;
  int? lastExpectedRevision;
  String? lastRollbackText;
  final List<int> releasedTokens = <int>[];

  @override
  bool probeAbi() => isAvailable;

  @override
  WindowsNativeClipboardCapture capture({
    required int ownerWindow,
    required int maximumBytes,
  }) {
    lastOwnerWindow = ownerWindow;
    lastMaximumBytes = maximumBytes;
    return captureResult;
  }

  @override
  int release(int token) {
    releasedTokens.add(token);
    return releaseStatus;
  }

  @override
  WindowsNativeClipboardRestore restore({
    required int ownerWindow,
    required int token,
    required int expectedRevision,
    required String rollbackText,
  }) {
    lastOwnerWindow = ownerWindow;
    lastExpectedRevision = expectedRevision;
    lastRollbackText = rollbackText;
    return restoreResult;
  }
}
