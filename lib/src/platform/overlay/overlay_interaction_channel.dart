import 'package:flutter/services.dart';

abstract interface class OverlayInteractionChannel {
  Future<void> watchOutsideClick(bool enabled);

  set onOutsideClick(void Function()? handler);
}

final class MethodChannelOverlayInteraction
    implements OverlayInteractionChannel {
  MethodChannelOverlayInteraction({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('ykd/overlay') {
    _channel.setMethodCallHandler(_handleCall);
  }

  final MethodChannel _channel;
  void Function()? _onOutsideClick;

  @override
  set onOutsideClick(void Function()? handler) => _onOutsideClick = handler;

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method == 'onOutsideClick') {
      _onOutsideClick?.call();
    }
    return null;
  }

  @override
  Future<void> watchOutsideClick(bool enabled) async {
    try {
      await _channel.invokeMethod<void>(
        'watchOutsideClick',
        <String, bool>{'enabled': enabled},
      );
    } catch (_) {}
  }
}

final class NoopOverlayInteraction implements OverlayInteractionChannel {
  const NoopOverlayInteraction();

  @override
  Future<void> watchOutsideClick(bool enabled) async {}

  @override
  set onOutsideClick(void Function()? handler) {}
}
