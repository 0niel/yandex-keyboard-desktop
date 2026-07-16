import 'package:yandex_keyboard_desktop/src/platform/selection/platform_selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';

final class ManualClipboardSelectionBackend
    implements
        SelectionBackend,
        ManualPasteSelectionBackend,
        ClipboardRecoveryBackend,
        SelectionBackendLifecycle {
  ManualClipboardSelectionBackend({
    ClipboardTextGateway clipboard = const FlutterClipboardTextGateway(),
    this.maxTextLength = 1 * 1024 * 1024,
  })  : assert(maxTextLength > 0),
        _clipboard = clipboard;

  static const _target = SelectionTarget('manual-clipboard');

  final ClipboardTextGateway _clipboard;
  final int maxTextLength;
  bool _disposed = false;
  int _revision = 0;
  String? _sourceText;
  String? _stagedText;

  @override
  Future<SelectionTarget> captureTarget() async {
    _ensureActive();
    if (hasPendingClipboardRecovery) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'clipboard_recovery_manual_action_required',
      );
    }
    return _target;
  }

  @override
  void releaseTarget(SelectionTarget target) {
    if (hasPendingClipboardRecovery) return;
    _sourceText = null;
    _stagedText = null;
  }

  @override
  bool get hasPendingClipboardRecovery =>
      _sourceText != null && _stagedText != null;

  @override
  bool get clipboardRecoveryRequiresManualAction => hasPendingClipboardRecovery;

  @override
  Future<ClipboardSnapshot> snapshotClipboard() async {
    _ensureActive();
    final text = await _readClipboard();
    if (text.trim().isEmpty) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.staleCopy,
        diagnosticCode: 'manual_clipboard_text_missing',
      );
    }
    if (text.length > maxTextLength) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.unsupported,
        diagnosticCode: 'manual_clipboard_text_too_large',
      );
    }
    _sourceText = text;
    return ClipboardSnapshot(revision: ++_revision, nativeData: text);
  }

  @override
  Future<SelectionCopy> copySelection(
    SelectionTarget target,
    ClipboardSnapshot snapshot, {
    required int maxAttempts,
    required Duration retryDelay,
  }) async {
    _ensureTarget(target);
    final text = snapshot.nativeData;
    if (text is! String || text.trim().isEmpty) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.staleCopy,
        diagnosticCode: 'manual_clipboard_text_missing',
      );
    }
    return SelectionCopy(text: text, ownedClipboardRevision: null);
  }

  @override
  Future<bool> isSameTarget(SelectionTarget target) async {
    return !_disposed && target.id == _target.id;
  }

  @override
  Future<void> focus(SelectionTarget target) async {
    _ensureTarget(target);
  }

  @override
  Future<ClipboardLease> stageReplacement(
    SelectionTarget target,
    String text, {
    required int expectedRevision,
    required String rollbackText,
  }) async {
    _ensureTarget(target);
    if (expectedRevision != _revision ||
        _sourceText != rollbackText ||
        await _readClipboard() != rollbackText) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'manual_clipboard_changed_before_result',
      );
    }
    if (text.length > maxTextLength) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.unsupported,
        diagnosticCode: 'manual_clipboard_text_too_large',
      );
    }
    final stagedRevision = ++_revision;
    _stagedText = text;
    try {
      await _clipboard.writeText(text);
      if (await _readClipboard() != text) {
        throw const SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'manual_clipboard_result_not_retained',
        );
      }
    } on SelectionBackendException catch (error) {
      throw SelectionBackendException(
        kind: error.kind,
        diagnosticCode: error.diagnosticCode,
        ownedClipboardRevision: stagedRevision,
      );
    } catch (_) {
      throw SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'manual_clipboard_write_failed',
        ownedClipboardRevision: stagedRevision,
      );
    }
    return ClipboardLease(
      target: target,
      clipboardRevision: stagedRevision,
    );
  }

  @override
  Future<CommitVerification> commitReplacement(ClipboardLease lease) async {
    _ensureTarget(lease.target);
    final stagedText = _stagedText;
    if (stagedText == null ||
        lease.clipboardRevision != _revision ||
        await _readClipboard() != stagedText) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'manual_clipboard_changed_after_result',
      );
    }
    return CommitVerification.verified;
  }

  @override
  Future<ClipboardRestoreResult> restoreClipboard(
    ClipboardSnapshot snapshot, {
    required int expectedRevision,
    bool restoreOriginal = true,
  }) async {
    if (!restoreOriginal) {
      _clearRecoveryState();
      return ClipboardRestoreResult.keptReplacement;
    }
    final stagedText = _stagedText;
    if (expectedRevision != _revision ||
        stagedText == null ||
        await _readClipboard() != stagedText) {
      _stagedText = null;
      return ClipboardRestoreResult.skippedExternalChange;
    }
    final original = snapshot.nativeData;
    if (original is! String) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.unsupported,
        diagnosticCode: 'manual_clipboard_snapshot_invalid',
      );
    }
    try {
      await _clipboard.writeText(original);
      if (await _readClipboard() != original) {
        throw const SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'manual_clipboard_restore_not_retained',
        );
      }
    } on SelectionBackendException {
      rethrow;
    } catch (_) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'manual_clipboard_restore_failed',
      );
    }
    _clearRecoveryState();
    return ClipboardRestoreResult.restored;
  }

  @override
  Future<bool> retryClipboardRecovery() async {
    if (!hasPendingClipboardRecovery) return true;
    final original = _sourceText!;
    final staged = _stagedText!;
    try {
      final current = await _readClipboard();
      if (current != staged) {
        _clearRecoveryState();
        return true;
      }
      await _clipboard.writeText(original);
      if (await _readClipboard() != original) return false;
      _clearRecoveryState();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> prepareForShutdown() async {
    if (!await retryClipboardRecovery()) return false;
    _disposed = true;
    _clearRecoveryState();
    return true;
  }

  void _clearRecoveryState() {
    _sourceText = null;
    _stagedText = null;
  }

  void _ensureActive() {
    if (_disposed) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.unsupported,
        diagnosticCode: 'selection_backend_disposed',
      );
    }
  }

  void _ensureTarget(SelectionTarget target) {
    _ensureActive();
    if (target.id != _target.id) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.targetChanged,
        diagnosticCode: 'manual_clipboard_target_changed',
      );
    }
  }

  Future<String> _readClipboard() async {
    try {
      return await _clipboard.readText();
    } catch (_) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'manual_clipboard_read_failed',
      );
    }
  }
}
