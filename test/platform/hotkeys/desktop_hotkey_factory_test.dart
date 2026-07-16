import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/desktop_hotkey_factory.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/global_shortcuts_portal_bridge.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_manager_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_runtime_state.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/noop_hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/windows_hotkey_registrar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recognizes native Wayland but not forced X11', () {
    expect(
        isNativeWaylandSession(const {'WAYLAND_DISPLAY': 'wayland-0'}), true);
    expect(
      isNativeWaylandSession(const {
        'WAYLAND_DISPLAY': 'wayland-0',
        'GDK_BACKEND': 'X11',
      }),
      false,
    );
    expect(isNativeWaylandSession(const {}), false);
  });

  test('Wayland portal shortcuts stay available in manual clipboard mode', () {
    final bridge = _NoopPortalBridge();
    final registrar = createDesktopHotkeyRegistrar(
      isLinux: true,
      requiresManualPaste: true,
      environment: const {'WAYLAND_DISPLAY': 'wayland-0'},
      portalBridge: bridge,
    );

    expect(registrar, isA<HotkeyRuntimeSource>());
  });

  test('manual non-Wayland mode is no-op; each desktop has its own registrar',
      () {
    expect(
      createDesktopHotkeyRegistrar(
        isLinux: true,
        requiresManualPaste: true,
        environment: const {},
      ),
      isA<NoOpHotkeyRegistrar>(),
    );
    expect(
      createDesktopHotkeyRegistrar(
        isLinux: true,
        requiresManualPaste: false,
        environment: const {},
      ),
      isA<HotKeyManagerRegistrar>(),
    );
    expect(
      createDesktopHotkeyRegistrar(
        isLinux: false,
        requiresManualPaste: false,
        environment: const {},
        windowsChannel: _UnusedNativeHotkeyChannel(),
      ),
      isA<WindowsHotkeyRegistrar>(),
    );
  });
}

final class _UnusedNativeHotkeyChannel implements NativeHotkeyChannel {
  @override
  Future<bool> register({
    required int id,
    required int modifiers,
    required int key,
  }) async =>
      true;

  @override
  Future<bool> unregister({required int id}) async => true;

  @override
  Future<bool> unregisterAll() async => true;

  @override
  set onHotKey(void Function(int id)? handler) {}
}

final class _NoopPortalBridge implements GlobalShortcutsPortalBridge {
  @override
  Stream<GlobalShortcutsPortalEvent> get events => const Stream.empty();

  @override
  Future<PortalBindResult> bindCandidate(PortalCandidateSession candidate) =>
      throw UnimplementedError();

  @override
  Future<void> cancelPendingRequest() async {}

  @override
  Future<void> closeSessions() async {}

  @override
  Future<void> commitCandidate(PortalCandidateSession candidate) async {}

  @override
  Future<void> configureShortcuts() async {}

  @override
  Future<PortalCandidateSession> createCandidate({
    required int generation,
    required List<PortalShortcutDefinition> shortcuts,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> discardCandidate(PortalCandidateSession candidate) async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<GlobalShortcutsCapability> getCapability() async =>
      const GlobalShortcutsCapability(available: false, version: 0);
}
