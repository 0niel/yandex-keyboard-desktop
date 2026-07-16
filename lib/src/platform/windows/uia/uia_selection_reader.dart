import 'package:yandex_keyboard_desktop/src/platform/selection/direct_selection_reader.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/uia/windows_uia_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/windows_target_identity.dart';

final class UiaSelectionReader implements DirectSelectionReader {
  UiaSelectionReader({
    required WindowsUiaGateway gateway,
    this.maxTextLength = 100000,
  })  : assert(maxTextLength > 0),
        _gateway = gateway;

  final WindowsUiaGateway _gateway;
  final int maxTextLength;
  final Map<DirectSelectionTarget, WindowsTargetIdentity> _identities = {};

  @override
  Future<DirectSelectionRead> readSelection(
    DirectSelectionTarget target,
  ) async {
    final probe = await _gateway.readSelection(
      target,
      maxTextLength: maxTextLength,
    );
    switch (probe.status) {
      case WindowsUiaProbeStatus.success:
        final identity = probe.identity;
        final text = probe.text;
        if (identity == null || text == null || text.isEmpty) {
          return const DirectSelectionRejected(
            kind: SelectionFailureKind.staleCopy,
            diagnosticCode: 'windows_uia_invalid_success',
          );
        }
        _identities[target] = identity;
        return DirectSelectionSuccess(text);
      case WindowsUiaProbeStatus.patternUnavailable:
        final identity = probe.identity;
        if (identity != null) {
          _identities[target] = identity;
        }
        return DirectSelectionUnavailable(
          'windows_uia_text_pattern_unavailable',
          targetIdentityCaptured: identity != null,
        );
      case WindowsUiaProbeStatus.accessDenied:
        return const DirectSelectionRejected(
          kind: SelectionFailureKind.permissionDenied,
          diagnosticCode: 'windows_uia_access_denied',
        );
      case WindowsUiaProbeStatus.passwordControl:
        return const DirectSelectionRejected(
          kind: SelectionFailureKind.permissionDenied,
          diagnosticCode: 'windows_uia_password_control',
        );
      case WindowsUiaProbeStatus.targetChanged:
        return const DirectSelectionRejected(
          kind: SelectionFailureKind.targetChanged,
          diagnosticCode: 'windows_uia_target_changed',
        );
      case WindowsUiaProbeStatus.noSelection:
        return const DirectSelectionUnavailable(
          'windows_uia_no_selection',
          targetIdentityCaptured: false,
        );
      case WindowsUiaProbeStatus.multipleSelection:
        return const DirectSelectionRejected(
          kind: SelectionFailureKind.unsupported,
          diagnosticCode: 'windows_uia_multiple_selection_unsupported',
        );
      case WindowsUiaProbeStatus.selectionTooLarge:
        return const DirectSelectionRejected(
          kind: SelectionFailureKind.unsupported,
          diagnosticCode: 'windows_uia_selection_too_large',
        );
      case WindowsUiaProbeStatus.providerFailure:
        return const DirectSelectionRejected(
          kind: SelectionFailureKind.unsupported,
          diagnosticCode: 'windows_uia_provider_failure',
        );
      case WindowsUiaProbeStatus.timeout:
        return const DirectSelectionRejected(
          kind: SelectionFailureKind.unsupported,
          diagnosticCode: 'windows_uia_provider_timeout',
        );
    }
  }

  @override
  Future<bool> isSameTarget(DirectSelectionTarget target) async {
    final expected = _identities[target];
    if (expected == null) return false;
    final probe = await _gateway.inspectFocusedTarget(target);
    final actual = probe.identity;
    return probe.status == WindowsUiaProbeStatus.success &&
        actual != null &&
        expected.hasSameControl(actual);
  }

  @override
  void releaseTarget(DirectSelectionTarget target) {
    _identities.remove(target);
  }
}
