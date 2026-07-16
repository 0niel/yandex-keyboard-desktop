import 'package:flutter/services.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';

abstract interface class IosKeyboardSettingsGateway {
  Future<Map<String, Object?>> read();

  Future<Map<String, Object?>> capabilities();

  Future<void> write(AppSettings settings);
}

final class MethodChannelIosKeyboardSettingsGateway
    implements IosKeyboardSettingsGateway {
  const MethodChannelIosKeyboardSettingsGateway({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'io.github.oniel.ykd/keyboard_settings';
  final MethodChannel _channel;

  @override
  Future<Map<String, Object?>> read() => _invokeMap('read');

  @override
  Future<Map<String, Object?>> capabilities() => _invokeMap('capabilities');

  @override
  Future<void> write(AppSettings settings) async {
    await _channel.invokeMethod<Object?>('write', {
      'schemaVersion': 1,
      'locale': settings.locale,
      'defaultAction': settings.defaultAction.name,
      'requestTimeoutMilliseconds': settings.requestTimeoutMilliseconds,
    });
  }

  Future<Map<String, Object?>> _invokeMap(String method) async {
    final raw = await _channel.invokeMapMethod<String, Object?>(method);
    if (raw == null) {
      throw PlatformException(
        code: 'invalid_keyboard_bridge_response',
        message: 'The iOS keyboard bridge returned no payload.',
      );
    }
    return Map.unmodifiable(raw);
  }
}

final class IosKeyboardSettingsApplier implements SettingsRuntimeApplier {
  const IosKeyboardSettingsApplier(this.gateway);

  final IosKeyboardSettingsGateway gateway;

  @override
  Future<void> apply({
    required AppSettings previous,
    required AppSettings next,
  }) =>
      gateway.write(next);
}
