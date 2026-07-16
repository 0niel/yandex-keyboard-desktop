import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/ios/ios_keyboard_settings_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/ios_keyboard_settings');
  const gateway = MethodChannelIosKeyboardSettingsGateway(channel: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('publishes only the extension allowlist', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return call.arguments;
    });
    final settings = AppSettings.defaults().copyWith(
      locale: 'ru',
      defaultAction: ShortcutAction.fix,
      requestTimeoutMilliseconds: 7000,
      historyEnabled: true,
      diagnosticsEnabled: true,
    );

    await gateway.write(settings);

    expect(received?.method, 'write');
    expect(received?.arguments, {
      'schemaVersion': 1,
      'locale': 'ru',
      'defaultAction': 'fix',
      'requestTimeoutMilliseconds': 7000,
    });
  });

  test('reads typed capability maps', () async {
    messenger.setMockMethodCallHandler(
        channel,
        (call) async => {
              'appGroupAvailable': true,
              'globalShortcuts': false,
            });

    expect(await gateway.capabilities(), {
      'appGroupAvailable': true,
      'globalShortcuts': false,
    });
  });

  test('rejects a missing native payload', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);

    await expectLater(
      gateway.read(),
      throwsA(isA<PlatformException>()),
    );
  });
}
