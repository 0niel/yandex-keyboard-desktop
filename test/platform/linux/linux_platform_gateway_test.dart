import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/linux/linux_native_bridge.dart';
import 'package:yandex_keyboard_desktop/src/platform/linux/linux_platform_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_platform_gateway.dart';

void main() {
  test('parses a closed native capability map', () {
    final capabilities = LinuxNativeCapabilities.fromMap(const {
      'displayServer': 'x11',
      'targetWindows': true,
      'inputInjection': true,
      'xfixes': true,
      'xresPid': true,
      'clipboardRevision': true,
      'clipboardOwnership': true,
      'losslessTextClipboardSnapshot': false,
      'stableClipboardReads': false,
      'nativeClipboardSnapshots': false,
      'atomicClipboardTransactions': false,
    });

    expect(capabilities.displayServer, LinuxDisplayServer.x11);
    expect(capabilities.targetWindows, isTrue);
    expect(capabilities.xfixes, isTrue);
    expect(capabilities.xresPid, isTrue);
    expect(capabilities.losslessTextClipboardSnapshot, isFalse);
  });

  test('rejects malformed native capabilities', () {
    expect(
      () => LinuxNativeCapabilities.fromMap(const {
        'displayServer': 'x11',
        'targetWindows': 1,
        'inputInjection': true,
        'xfixes': true,
        'xresPid': true,
        'clipboardRevision': true,
        'clipboardOwnership': true,
        'losslessTextClipboardSnapshot': false,
        'stableClipboardReads': false,
        'nativeClipboardSnapshots': false,
        'atomicClipboardTransactions': false,
      }),
      throwsFormatException,
    );
  });

  test('delegates X11 target identity and clipboard facts', () async {
    final bridge = _FakeLinuxNativeBridge();
    final gateway = LinuxPlatformGateway(
      bridge: bridge,
      clipboard: const _FakeLinuxClipboardGateway('selected'),
      copySettleDelay: Duration.zero,
      focusSettleDelay: Duration.zero,
    )..setOriginalForegroundWindow(41);

    expect(await gateway.getForegroundWindow(), 41);
    expect(gateway.getOriginalForegroundWindow(), 41);
    expect(await gateway.getWindowProcessId(41), 73);
    expect(await gateway.isWindowValid(41), isTrue);
    expect(await gateway.getClipboardRevision(), 9);
    expect(await gateway.isClipboardOwnedByTarget(41), isTrue);
    expect(await gateway.getFlutterWindowHandle(), 99);
    expect(await gateway.supportsLosslessTextClipboardSnapshot(), isFalse);
  });

  test('injects balanced copy and paste only when capability is present',
      () async {
    final bridge = _FakeLinuxNativeBridge();
    final gateway = LinuxPlatformGateway(
      bridge: bridge,
      clipboard: const _FakeLinuxClipboardGateway('selected'),
      copySettleDelay: Duration.zero,
      focusSettleDelay: Duration.zero,
    );

    expect(await gateway.focusWindow(41), isTrue);
    expect(await gateway.getSelectedText(41), 'selected');
    await gateway.replaceSelectedText(41, 'replacement');

    expect(bridge.copyHandles, [41]);
    expect(bridge.pasteHandles, [41]);
  });

  test('delegates owned-window activation without requiring an X11 handle',
      () async {
    final bridge = _FakeLinuxNativeBridge();
    final gateway = LinuxPlatformGateway(bridge: bridge);

    await gateway.setOwnedWindowCanActivate(false);
    await gateway.showOwnedWindowInactive();
    await gateway.setOwnedWindowCanActivate(true);

    expect(bridge.activationChanges, [false, true]);
    expect(bridge.inactiveShowCalls, 1);
  });

  test('fails closed when the display server cannot inject input', () async {
    final bridge = _FakeLinuxNativeBridge(inputInjection: false);
    final gateway = LinuxPlatformGateway(
      bridge: bridge,
      clipboard: const _FakeLinuxClipboardGateway('selected'),
      copySettleDelay: Duration.zero,
    );

    await expectLater(
      gateway.getSelectedText(41),
      throwsA(isA<UnsupportedError>()),
    );
    expect(bridge.copyHandles, isEmpty);
  });

  test('enables automatic replacement only for the complete evidence chain',
      () async {
    final complete = LinuxPlatformGateway(
      bridge: _FakeLinuxNativeBridge(
        losslessTextClipboardSnapshot: true,
        stableClipboardReads: true,
        nativeClipboardSnapshots: true,
        atomicClipboardTransactions: true,
      ),
    );
    final incomplete = LinuxPlatformGateway(
      bridge: _FakeLinuxNativeBridge(
        inputInjection: false,
        losslessTextClipboardSnapshot: true,
        stableClipboardReads: true,
        nativeClipboardSnapshots: true,
        atomicClipboardTransactions: true,
      ),
    );

    expect(await complete.supportsAutomaticSelectionReplacement(), isTrue);
    expect(await incomplete.supportsAutomaticSelectionReplacement(), isFalse);
  });

  test('delegates proven native snapshot, stable read, and CAS capabilities',
      () async {
    final bridge = _FakeLinuxNativeBridge(
      losslessTextClipboardSnapshot: true,
      stableClipboardReads: true,
      nativeClipboardSnapshots: true,
      atomicClipboardTransactions: true,
    );
    final gateway = LinuxPlatformGateway(bridge: bridge);

    expect(await gateway.supportsStableClipboardTextReads(), isTrue);
    expect(await gateway.supportsLosslessTextClipboardSnapshot(), isTrue);
    expect(await gateway.supportsNativeClipboardSnapshots(), isTrue);
    expect(gateway.supportsAtomicTextClipboardTransactions(), isTrue);
    final read = await gateway.copySelectionTextWithEvidence(41);
    final snapshot = await gateway.captureNativeClipboardSnapshot();
    expect(read.ownerProcessId, 73);
    expect(snapshot.payload, 17);
    expect(
      await gateway.writeClipboardTextIfRevision(
        'replacement',
        expectedRevision: 9,
        rollbackText: 'selected',
      ),
      10,
    );
    expect(
      await gateway.restoreNativeClipboardSnapshotIfRevision(
        snapshot.payload,
        expectedRevision: 10,
        rollbackText: 'replacement',
      ),
      11,
    );
    await gateway.releaseNativeClipboardSnapshot(snapshot.payload);
    expect(bridge.releasedSnapshots, [17]);
  });

  test('fails closed when native snapshot lacks a stable attributed read',
      () async {
    final bridge = _FakeLinuxNativeBridge(
      nativeClipboardSnapshots: true,
      atomicClipboardTransactions: true,
    );
    final gateway = LinuxPlatformGateway(
      bridge: bridge,
      clipboard: const _FakeLinuxClipboardGateway('stale'),
      copySettleDelay: Duration.zero,
    );

    expect(await gateway.supportsLosslessTextClipboardSnapshot(), isFalse);
    expect(await gateway.supportsNativeClipboardSnapshots(), isFalse);
    expect(await gateway.supportsStableClipboardTextReads(), isFalse);
    expect(gateway.supportsAtomicTextClipboardTransactions(), isFalse);
    expect(bridge.copyHandles, isEmpty);
  });
}

final class _FakeLinuxClipboardGateway implements LinuxClipboardGateway {
  const _FakeLinuxClipboardGateway(this.text);

  final String text;

  @override
  Future<String> readText() async => text;
}

final class _FakeLinuxNativeBridge implements LinuxNativeBridge {
  _FakeLinuxNativeBridge({
    this.inputInjection = true,
    this.losslessTextClipboardSnapshot = false,
    this.stableClipboardReads = false,
    this.nativeClipboardSnapshots = false,
    this.atomicClipboardTransactions = false,
  });

  final bool inputInjection;
  final bool losslessTextClipboardSnapshot;
  final bool stableClipboardReads;
  final bool nativeClipboardSnapshots;
  final bool atomicClipboardTransactions;
  final List<int> copyHandles = [];
  final List<int> pasteHandles = [];
  final List<Object> releasedSnapshots = [];
  final List<bool> activationChanges = [];
  int inactiveShowCalls = 0;

  @override
  Future<LinuxNativeCapabilities> getCapabilities() async {
    return LinuxNativeCapabilities(
      displayServer: LinuxDisplayServer.x11,
      targetWindows: true,
      inputInjection: inputInjection,
      xfixes: true,
      xresPid: true,
      clipboardRevision: true,
      clipboardOwnership: true,
      losslessTextClipboardSnapshot: losslessTextClipboardSnapshot,
      stableClipboardReads: stableClipboardReads,
      nativeClipboardSnapshots: nativeClipboardSnapshots,
      atomicClipboardTransactions: atomicClipboardTransactions,
    );
  }

  @override
  Future<int> getClipboardRevision() async => 9;

  @override
  Future<int> getFlutterWindowHandle() async => 99;

  @override
  Future<int> getForegroundWindow() async => 41;

  @override
  Future<int> getWindowProcessId(int handle) async => handle == 41 ? 73 : 0;

  @override
  Future<void> injectCopy(int handle) async => copyHandles.add(handle);

  @override
  Future<void> injectPaste(int handle) async => pasteHandles.add(handle);

  @override
  Future<void> setApplicationWindowCanActivate(bool canActivate) async {
    activationChanges.add(canActivate);
  }

  @override
  Future<void> showApplicationWindowInactive() async {
    inactiveShowCalls++;
  }

  @override
  Future<bool> isClipboardOwnedByTarget(int handle) async => handle == 41;

  @override
  Future<bool> isWindowValid(int handle) async => handle == 41;

  @override
  Future<bool> focusWindow(int handle) async => handle == 41;

  @override
  Future<StableClipboardTextRead> copySelectionTextWithEvidence(
    int handle, {
    required int maxBytes,
    required int maxTargets,
    required int timeoutMilliseconds,
  }) async =>
      StableClipboardTextRead(
        text: 'selected',
        revision: 9,
        ownerProcessId: 73,
      );

  @override
  Future<PlatformClipboardSnapshot> captureNativeClipboardSnapshot({
    required int maxBytes,
    required int maxTargets,
    required int timeoutMilliseconds,
  }) async =>
      const PlatformClipboardSnapshot(revision: 9, payload: 17);

  @override
  Future<int?> writeClipboardTextIfRevision(
    String text, {
    required int expectedRevision,
    required String rollbackText,
  }) async =>
      10;

  @override
  Future<int?> restoreNativeClipboardSnapshotIfRevision(
    Object snapshotId, {
    required int expectedRevision,
    required String rollbackText,
  }) async =>
      11;

  @override
  Future<void> releaseNativeClipboardSnapshot(Object snapshotId) async {
    releasedSnapshots.add(snapshotId);
  }
}
