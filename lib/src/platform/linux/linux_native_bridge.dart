import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_platform_gateway.dart';

enum LinuxDisplayServer { x11, wayland, unknown }

final class LinuxNativeCapabilities {
  const LinuxNativeCapabilities({
    required this.displayServer,
    required this.targetWindows,
    required this.inputInjection,
    required this.xfixes,
    required this.xresPid,
    required this.clipboardRevision,
    required this.clipboardOwnership,
    required this.losslessTextClipboardSnapshot,
    required this.stableClipboardReads,
    required this.nativeClipboardSnapshots,
    required this.atomicClipboardTransactions,
  });

  factory LinuxNativeCapabilities.fromMap(Map<Object?, Object?> value) {
    bool readBool(String key) {
      final field = value[key];
      if (field is! bool) {
        throw FormatException('Invalid Linux capability: $key');
      }
      return field;
    }

    final displayServer = switch (value['displayServer']) {
      'x11' => LinuxDisplayServer.x11,
      'wayland' => LinuxDisplayServer.wayland,
      _ => LinuxDisplayServer.unknown,
    };
    return LinuxNativeCapabilities(
      displayServer: displayServer,
      targetWindows: readBool('targetWindows'),
      inputInjection: readBool('inputInjection'),
      xfixes: readBool('xfixes'),
      xresPid: readBool('xresPid'),
      clipboardRevision: readBool('clipboardRevision'),
      clipboardOwnership: readBool('clipboardOwnership'),
      losslessTextClipboardSnapshot: readBool('losslessTextClipboardSnapshot'),
      stableClipboardReads: readBool('stableClipboardReads'),
      nativeClipboardSnapshots: readBool('nativeClipboardSnapshots'),
      atomicClipboardTransactions: readBool('atomicClipboardTransactions'),
    );
  }

  final LinuxDisplayServer displayServer;
  final bool targetWindows;
  final bool inputInjection;
  final bool xfixes;
  final bool xresPid;
  final bool clipboardRevision;
  final bool clipboardOwnership;
  final bool losslessTextClipboardSnapshot;
  final bool stableClipboardReads;
  final bool nativeClipboardSnapshots;
  final bool atomicClipboardTransactions;
}

abstract interface class LinuxNativeBridge {
  Future<LinuxNativeCapabilities> getCapabilities();

  Future<int> getForegroundWindow();

  Future<int> getWindowProcessId(int handle);

  Future<int> getClipboardRevision();

  Future<bool> isWindowValid(int handle);

  Future<bool> focusWindow(int handle);

  Future<bool> isClipboardOwnedByTarget(int handle);

  Future<void> injectCopy(int handle);

  Future<void> injectPaste(int handle);

  Future<int> getFlutterWindowHandle();

  Future<void> setApplicationWindowCanActivate(bool canActivate);

  Future<void> showApplicationWindowInactive();

  Future<StableClipboardTextRead> copySelectionTextWithEvidence(
    int handle, {
    required int maxBytes,
    required int maxTargets,
    required int timeoutMilliseconds,
  });

  Future<PlatformClipboardSnapshot> captureNativeClipboardSnapshot({
    required int maxBytes,
    required int maxTargets,
    required int timeoutMilliseconds,
  });

  Future<int?> writeClipboardTextIfRevision(
    String text, {
    required int expectedRevision,
    required String rollbackText,
  });

  Future<int?> restoreNativeClipboardSnapshotIfRevision(
    Object snapshotId, {
    required int expectedRevision,
    required String rollbackText,
  });

  Future<void> releaseNativeClipboardSnapshot(Object snapshotId);
}

final class MethodChannelLinuxNativeBridge implements LinuxNativeBridge {
  const MethodChannelLinuxNativeBridge({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const _channelName =
      'io.github.oniel.yandex_keyboard_desktop/linux_native';
  final MethodChannel _channel;

  @override
  Future<LinuxNativeCapabilities> getCapabilities() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'getCapabilities',
    );
    if (result == null) {
      throw const FormatException('Missing Linux native capabilities');
    }
    return LinuxNativeCapabilities.fromMap(result);
  }

  @override
  Future<int> getForegroundWindow() => _readInt('getForegroundWindow');

  @override
  Future<int> getWindowProcessId(int handle) =>
      _readInt('getWindowProcessId', handle);

  @override
  Future<int> getClipboardRevision() => _readInt('getClipboardRevision');

  @override
  Future<bool> isWindowValid(int handle) => _readBool('isWindowValid', handle);

  @override
  Future<bool> focusWindow(int handle) => _readBool('focusWindow', handle);

  @override
  Future<bool> isClipboardOwnedByTarget(int handle) =>
      _readBool('isClipboardOwnedByTarget', handle);

  @override
  Future<void> injectCopy(int handle) => _channel.invokeMethod<void>(
        'injectCopy',
        handle,
      );

  @override
  Future<void> injectPaste(int handle) => _channel.invokeMethod<void>(
        'injectPaste',
        handle,
      );

  @override
  Future<int> getFlutterWindowHandle() => _readInt('getFlutterWindowHandle');

  @override
  Future<void> setApplicationWindowCanActivate(bool canActivate) =>
      _channel.invokeMethod<void>(
        'setApplicationWindowCanActivate',
        canActivate,
      );

  @override
  Future<void> showApplicationWindowInactive() =>
      _channel.invokeMethod<void>('showApplicationWindowInactive');

  @override
  Future<StableClipboardTextRead> copySelectionTextWithEvidence(
    int handle, {
    required int maxBytes,
    required int maxTargets,
    required int timeoutMilliseconds,
  }) async {
    final result = await _readMap('copySelectionTextWithEvidence', {
      'handle': handle,
      'maxBytes': maxBytes,
      'maxTargets': maxTargets,
      'timeoutMilliseconds': timeoutMilliseconds,
    });
    return StableClipboardTextRead(
      text: _mapString(result, 'text'),
      revision: _mapInt(result, 'revision'),
      ownerProcessId: _mapInt(result, 'ownerProcessId'),
    );
  }

  @override
  Future<PlatformClipboardSnapshot> captureNativeClipboardSnapshot({
    required int maxBytes,
    required int maxTargets,
    required int timeoutMilliseconds,
  }) async {
    final result = await _readMap('captureNativeClipboardSnapshot', {
      'maxBytes': maxBytes,
      'maxTargets': maxTargets,
      'timeoutMilliseconds': timeoutMilliseconds,
    });
    return PlatformClipboardSnapshot(
      revision: _mapInt(result, 'revision'),
      payload: _mapInt(result, 'snapshotId'),
    );
  }

  @override
  Future<int?> writeClipboardTextIfRevision(
    String text, {
    required int expectedRevision,
    required String rollbackText,
  }) =>
      _readNullableInt('writeClipboardTextIfRevision', {
        'text': _utf8Bytes(text),
        'expectedRevision': expectedRevision,
        'rollbackText': _utf8Bytes(rollbackText),
      });

  @override
  Future<int?> restoreNativeClipboardSnapshotIfRevision(
    Object snapshotId, {
    required int expectedRevision,
    required String rollbackText,
  }) =>
      _readNullableInt('restoreNativeClipboardSnapshotIfRevision', {
        'snapshotId': snapshotId,
        'expectedRevision': expectedRevision,
        'rollbackText': _utf8Bytes(rollbackText),
      });

  @override
  Future<void> releaseNativeClipboardSnapshot(Object snapshotId) =>
      _channel.invokeMethod<void>(
        'releaseNativeClipboardSnapshot',
        snapshotId,
      );

  Future<int> _readInt(String method, [Object? arguments]) async {
    final result = await _channel.invokeMethod<Object?>(method, arguments);
    if (result is! int) throw FormatException('Invalid $method response');
    return result;
  }

  Future<bool> _readBool(String method, [Object? arguments]) async {
    final result = await _channel.invokeMethod<Object?>(method, arguments);
    if (result is! bool) throw FormatException('Invalid $method response');
    return result;
  }

  Future<int?> _readNullableInt(String method, Object arguments) async {
    final result = await _channel.invokeMethod<Object?>(method, arguments);
    if (result == null || result is int) return result as int?;
    throw FormatException('Invalid $method response');
  }

  Future<Map<Object?, Object?>> _readMap(
    String method,
    Object arguments,
  ) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      method,
      arguments,
    );
    if (result == null) throw FormatException('Invalid $method response');
    return result;
  }

  int _mapInt(Map<Object?, Object?> map, String key) {
    final value = map[key];
    if (value is! int) throw FormatException('Invalid response field: $key');
    return value;
  }

  String _mapString(Map<Object?, Object?> map, String key) {
    final value = map[key];
    if (value is! String) {
      throw FormatException('Invalid response field: $key');
    }
    return value;
  }

  Uint8List _utf8Bytes(String value) => Uint8List.fromList(utf8.encode(value));
}
