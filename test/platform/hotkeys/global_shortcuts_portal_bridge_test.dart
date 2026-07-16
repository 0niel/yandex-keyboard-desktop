import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/global_shortcuts_portal_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('strictly validates capability and candidate DTOs', () {
    expect(
      () => GlobalShortcutsCapability.fromMap({
        'available': true,
        'version': 0,
      }),
      throwsFormatException,
    );
    expect(
      () => GlobalShortcutsCapability.fromMap({
        'available': 'yes',
        'version': 2,
      }),
      throwsFormatException,
    );
    expect(
      () => PortalCandidateSession.fromMap({'id': '', 'generation': 1}),
      throwsFormatException,
    );
  });

  test('retains trigger descriptions as opaque strings', () {
    final binding = PortalShortcutBinding.fromMap({
      'id': 'rewrite',
      'description': 'Rewrite text',
      'triggerDescription': 'Super + Ö (layout: custom)',
    });

    expect(binding.triggerDescription, 'Super + Ö (layout: custom)');
  });

  test('rejects malformed bind results and unknown events', () {
    expect(
      () => PortalBindResult.fromMap({
        'status': 'success',
        'bindings': [
          {'id': 'rewrite', 'description': 7},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => GlobalShortcutsPortalEvent.fromMap({
        'type': 'futureEvent',
        'generation': 1,
      }),
      throwsFormatException,
    );
  });

  test('method adapter sends definitions and strictly parses responses',
      () async {
    const channel = MethodChannel('test/global-shortcuts-methods');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'getGlobalShortcutsCapability' => {
            'available': true,
            'version': 2,
          },
        'createGlobalShortcutsCandidate' => {
            'id': 'candidate-7',
            'generation': 7,
          },
        'bindGlobalShortcutsCandidate' => {
            'status': 'success',
            'bindings': [
              {
                'id': 'rewrite',
                'description': 'Rewrite',
                'triggerDescription': 'Ctrl+Alt+R',
              },
            ],
          },
        _ => null,
      };
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final bridge = MethodChannelGlobalShortcutsPortalBridge(
      methodChannel: channel,
      rawEvents: const Stream.empty(),
    );

    expect(
      await bridge.getCapability(),
      const GlobalShortcutsCapability(available: true, version: 2),
    );
    final candidate = await bridge.createCandidate(
      generation: 7,
      shortcuts: [
        PortalShortcutDefinition(
          id: 'rewrite',
          description: 'Rewrite',
          preferredTrigger: 'CTRL+ALT+r',
        ),
      ],
    );
    final result = await bridge.bindCandidate(candidate);
    await bridge.commitCandidate(candidate);
    await bridge.discardCandidate(candidate);
    await bridge.cancelPendingRequest();
    await bridge.closeSessions();
    await bridge.configureShortcuts();
    await bridge.dispose();

    expect(candidate, PortalCandidateSession(id: 'candidate-7', generation: 7));
    expect(result.status, PortalBindStatus.success);
    expect(result.bindings.single.triggerDescription, 'Ctrl+Alt+R');
    expect(calls[1].arguments, {
      'generation': 7,
      'shortcuts': [
        {
          'id': 'rewrite',
          'description': 'Rewrite',
          'preferredTrigger': 'CTRL+ALT+r',
        },
      ],
    });
    expect(
      calls.map((call) => call.method),
      containsAll([
        'commitGlobalShortcutsCandidate',
        'discardGlobalShortcutsCandidate',
        'cancelGlobalShortcutsRequest',
        'closeGlobalShortcutsSessions',
        'configureGlobalShortcuts',
        'disposeGlobalShortcuts',
      ]),
    );
    await expectLater(
      bridge.createCandidate(generation: 0, shortcuts: const []),
      throwsArgumentError,
    );
  });

  test('method adapter rejects a non-map native response', () async {
    const channel = MethodChannel('test/global-shortcuts-invalid-response');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => 'invalid');
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final bridge = MethodChannelGlobalShortcutsPortalBridge(
      methodChannel: channel,
      rawEvents: const Stream.empty(),
    );

    await expectLater(bridge.getCapability(), throwsFormatException);
  });

  test('event adapter parses typed events and surfaces malformed data',
      () async {
    final rawEvents = StreamController<Object?>();
    final bridge = MethodChannelGlobalShortcutsPortalBridge(
      rawEvents: rawEvents.stream,
    );
    final events = <GlobalShortcutsPortalEvent>[];
    final errors = <Object>[];
    final subscription = bridge.events.listen(events.add, onError: errors.add);

    rawEvents.add({
      'type': 'activated',
      'generation': 3,
      'shortcutId': 'fix',
      'timestamp': 42,
      'activationToken': 'opaque-token',
    });
    rawEvents.add({'type': 'activated', 'generation': 'bad'});
    await pumpEventQueue();

    expect(events.single, isA<PortalShortcutActivated>());
    expect(
      (events.single as PortalShortcutActivated).activationToken,
      'opaque-token',
    );
    expect(errors.single, isA<FormatException>());

    await subscription.cancel();
    await rawEvents.close();
  });
}
