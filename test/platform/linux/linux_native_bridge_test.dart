import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/linux/linux_native_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('linux-native-bridge-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('decodes native capabilities and sends window handles unchanged',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'getCapabilities' => <String, Object>{
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
          },
        'getWindowProcessId' => 7331,
        'setApplicationWindowCanActivate' ||
        'showApplicationWindowInactive' =>
          null,
        'injectCopy' || 'injectPaste' => null,
        _ => throw PlatformException(code: 'unexpected_method'),
      };
    });
    final bridge = MethodChannelLinuxNativeBridge(channel: channel);

    final capabilities = await bridge.getCapabilities();
    expect(capabilities.displayServer, LinuxDisplayServer.x11);
    expect(capabilities.xfixes, isTrue);
    expect(capabilities.xresPid, isTrue);
    expect(await bridge.getWindowProcessId(0x1234), 7331);
    await bridge.injectCopy(0x1234);
    await bridge.injectPaste(0x1234);
    await bridge.setApplicationWindowCanActivate(false);
    await bridge.showApplicationWindowInactive();

    expect(
      calls.map((call) => (call.method, call.arguments)),
      [
        ('getCapabilities', null),
        ('getWindowProcessId', 0x1234),
        ('injectCopy', 0x1234),
        ('injectPaste', 0x1234),
        ('setApplicationWindowCanActivate', false),
        ('showApplicationWindowInactive', null),
      ],
    );
  });

  test('uses strict maps for stable reads, snapshots, and CAS', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'copySelectionTextWithEvidence' => <String, Object>{
            'text': 'selected',
            'revision': 7,
            'ownerWindow': 91,
            'ownerProcessId': 7331,
          },
        'captureNativeClipboardSnapshot' => <String, Object>{
            'revision': 6,
            'snapshotId': 44,
          },
        'writeClipboardTextIfRevision' => null,
        'restoreNativeClipboardSnapshotIfRevision' => 8,
        'releaseNativeClipboardSnapshot' => null,
        _ => throw PlatformException(code: 'unexpected_method'),
      };
    });
    final bridge = MethodChannelLinuxNativeBridge(channel: channel);

    final read = await bridge.copySelectionTextWithEvidence(
      41,
      maxBytes: 1024,
      maxTargets: 8,
      timeoutMilliseconds: 250,
    );
    final snapshot = await bridge.captureNativeClipboardSnapshot(
      maxBytes: 2048,
      maxTargets: 16,
      timeoutMilliseconds: 500,
    );
    expect(read.text, 'selected');
    expect(read.ownerProcessId, 7331);
    expect(snapshot.revision, 6);
    expect(snapshot.payload, 44);
    expect(
      await bridge.writeClipboardTextIfRevision(
        'замена\u0000',
        expectedRevision: 7,
        rollbackText: 'selected',
      ),
      isNull,
    );
    expect(
      await bridge.restoreNativeClipboardSnapshotIfRevision(
        44,
        expectedRevision: 7,
        rollbackText: 'replacement',
      ),
      8,
    );
    await bridge.releaseNativeClipboardSnapshot(44);

    expect(calls.map((call) => call.method), [
      'copySelectionTextWithEvidence',
      'captureNativeClipboardSnapshot',
      'writeClipboardTextIfRevision',
      'restoreNativeClipboardSnapshotIfRevision',
      'releaseNativeClipboardSnapshot',
    ]);
    final writeArguments = calls[2].arguments! as Map<Object?, Object?>;
    expect(
      writeArguments['text'],
      Uint8List.fromList(utf8.encode('замена\u0000')),
    );
    expect(writeArguments['rollbackText'],
        Uint8List.fromList('selected'.codeUnits));
    final restoreArguments = calls[3].arguments! as Map<Object?, Object?>;
    expect(
      restoreArguments['rollbackText'],
      Uint8List.fromList('replacement'.codeUnits),
    );
  });

  test('rejects malformed native transaction maps', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => <String, Object>{
        'text': 'selected',
        'revision': '7',
        'ownerWindow': 91,
        'ownerProcessId': 7331,
      },
    );
    final bridge = MethodChannelLinuxNativeBridge(channel: channel);

    await expectLater(
      bridge.copySelectionTextWithEvidence(
        41,
        maxBytes: 1024,
        maxTargets: 8,
        timeoutMilliseconds: 250,
      ),
      throwsFormatException,
    );
  });

  test('rejects malformed scalar responses instead of coercing them', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => '41');
    final bridge = MethodChannelLinuxNativeBridge(channel: channel);

    await expectLater(
      bridge.getForegroundWindow(),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      bridge.isWindowValid(41),
      throwsA(isA<FormatException>()),
    );
  });
}
