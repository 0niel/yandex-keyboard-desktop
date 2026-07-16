import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/direct_selection_reader.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/uia/uia_selection_reader.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/uia/windows_uia_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/windows_target_identity.dart';

void main() {
  const target = DirectSelectionTarget(windowHandle: 42, processId: 4242);
  final identity = WindowsTargetIdentity(
    windowHandle: 42,
    processId: 4242,
    runtimeId: [42, 7, 9],
  );

  test('returns direct text and retains only target identity', () async {
    final gateway = _FakeWindowsUiaGateway(
      readProbe: WindowsUiaProbe(
        status: WindowsUiaProbeStatus.success,
        identity: identity,
        text: 'selected',
      ),
      inspectProbe: WindowsUiaProbe(
        status: WindowsUiaProbeStatus.success,
        identity: identity,
      ),
    );
    final reader = UiaSelectionReader(gateway: gateway);

    final result = await reader.readSelection(target);

    expect(result, isA<DirectSelectionSuccess>());
    expect((result as DirectSelectionSuccess).text, 'selected');
    expect(await reader.isSameTarget(target), isTrue);
    reader.releaseTarget(target);
    expect(await reader.isSameTarget(target), isFalse);
  });

  test('permits fallback only when TextPattern is unavailable', () async {
    final reader = UiaSelectionReader(
      gateway: _FakeWindowsUiaGateway(
        readProbe: const WindowsUiaProbe(
          status: WindowsUiaProbeStatus.patternUnavailable,
        ),
      ),
    );

    expect(
      await reader.readSelection(target),
      isA<DirectSelectionUnavailable>(),
    );
  });

  test('permits guarded fallback when the provider reports no selection',
      () async {
    final reader = UiaSelectionReader(
      gateway: _FakeWindowsUiaGateway(
        readProbe: const WindowsUiaProbe(
          status: WindowsUiaProbeStatus.noSelection,
        ),
      ),
    );

    final result = await reader.readSelection(target);

    expect(result, isA<DirectSelectionUnavailable>());
    final unavailable = result as DirectSelectionUnavailable;
    expect(unavailable.diagnosticCode, 'windows_uia_no_selection');
    expect(unavailable.targetIdentityCaptured, isFalse);
  });

  test('retains exact control identity for TextPattern fallback', () async {
    final reader = UiaSelectionReader(
      gateway: _FakeWindowsUiaGateway(
        readProbe: WindowsUiaProbe(
          status: WindowsUiaProbeStatus.patternUnavailable,
          identity: identity,
        ),
        inspectProbe: WindowsUiaProbe(
          status: WindowsUiaProbeStatus.success,
          identity: identity,
        ),
      ),
    );

    final result = await reader.readSelection(target);

    expect(result, isA<DirectSelectionUnavailable>());
    expect(
      (result as DirectSelectionUnavailable).targetIdentityCaptured,
      isTrue,
    );
    expect(await reader.isSameTarget(target), isTrue);
  });

  for (final testCase
      in <(WindowsUiaProbeStatus, SelectionFailureKind, String)>[
    (
      WindowsUiaProbeStatus.passwordControl,
      SelectionFailureKind.permissionDenied,
      'windows_uia_password_control',
    ),
    (
      WindowsUiaProbeStatus.accessDenied,
      SelectionFailureKind.permissionDenied,
      'windows_uia_access_denied',
    ),
    (
      WindowsUiaProbeStatus.targetChanged,
      SelectionFailureKind.targetChanged,
      'windows_uia_target_changed',
    ),
    (
      WindowsUiaProbeStatus.multipleSelection,
      SelectionFailureKind.unsupported,
      'windows_uia_multiple_selection_unsupported',
    ),
    (
      WindowsUiaProbeStatus.selectionTooLarge,
      SelectionFailureKind.unsupported,
      'windows_uia_selection_too_large',
    ),
    (
      WindowsUiaProbeStatus.providerFailure,
      SelectionFailureKind.unsupported,
      'windows_uia_provider_failure',
    ),
    (
      WindowsUiaProbeStatus.timeout,
      SelectionFailureKind.unsupported,
      'windows_uia_provider_timeout',
    ),
  ]) {
    test('${testCase.$1} is rejected without fallback', () async {
      final reader = UiaSelectionReader(
        gateway: _FakeWindowsUiaGateway(
          readProbe: WindowsUiaProbe(status: testCase.$1),
        ),
      );

      final result = await reader.readSelection(target);

      expect(result, isA<DirectSelectionRejected>());
      final rejected = result as DirectSelectionRejected;
      expect(rejected.kind, testCase.$2);
      expect(rejected.diagnosticCode, testCase.$3);
    });
  }

  test('rejects malformed success without retaining text or identity',
      () async {
    final reader = UiaSelectionReader(
      gateway: _FakeWindowsUiaGateway(
        readProbe: WindowsUiaProbe(
          status: WindowsUiaProbeStatus.success,
          identity: identity,
          text: '',
        ),
      ),
    );

    final result = await reader.readSelection(target);

    expect(result, isA<DirectSelectionRejected>());
    expect(await reader.isSameTarget(target), isFalse);
  });

  test('detects a focused control runtime identity change', () async {
    final changedIdentity = WindowsTargetIdentity(
      windowHandle: 42,
      processId: 4242,
      runtimeId: [42, 7, 10],
    );
    final gateway = _FakeWindowsUiaGateway(
      readProbe: WindowsUiaProbe(
        status: WindowsUiaProbeStatus.success,
        identity: identity,
        text: 'selected',
      ),
      inspectProbe: WindowsUiaProbe(
        status: WindowsUiaProbeStatus.success,
        identity: changedIdentity,
      ),
    );
    final reader = UiaSelectionReader(gateway: gateway);
    await reader.readSelection(target);

    expect(await reader.isSameTarget(target), isFalse);
  });
}

final class _FakeWindowsUiaGateway implements WindowsUiaGateway {
  _FakeWindowsUiaGateway({
    required this.readProbe,
    this.inspectProbe = const WindowsUiaProbe(
      status: WindowsUiaProbeStatus.providerFailure,
    ),
  });

  final WindowsUiaProbe readProbe;
  final WindowsUiaProbe inspectProbe;

  @override
  Future<WindowsUiaProbe> inspectFocusedTarget(
    DirectSelectionTarget target,
  ) async =>
      inspectProbe;

  @override
  Future<WindowsUiaProbe> readSelection(
    DirectSelectionTarget target, {
    required int maxTextLength,
  }) async =>
      readProbe;
}
