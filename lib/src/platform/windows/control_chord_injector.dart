import 'package:yandex_keyboard_desktop/src/platform/windows/keyboard_input_gateway.dart';

final class PartialKeyboardInjectionException implements Exception {
  const PartialKeyboardInjectionException({
    required this.sent,
    required this.expected,
  });

  final int sent;
  final int expected;

  @override
  String toString() =>
      'Keyboard injection sent $sent of $expected requested events.';
}

void sendKeyboardStrokesChecked(
  KeyboardInputGateway gateway,
  List<KeyboardStroke> strokes,
) {
  final sent = gateway.send(strokes);
  if (sent != strokes.length) {
    throw PartialKeyboardInjectionException(
      sent: sent,
      expected: strokes.length,
    );
  }
}

void releaseKeyboardStrokesBestEffort(
  KeyboardInputGateway gateway,
  List<KeyboardStroke> strokes,
) {
  for (final stroke in strokes) {
    if (gateway.send([stroke]) != 1) {
      gateway.send([stroke]);
    }
  }
}

final class ControlChordInjector {
  const ControlChordInjector({
    required KeyboardInputGateway gateway,
    required this.controlVirtualKey,
    this.gap = const Duration(milliseconds: 12),
  }) : _gateway = gateway;

  final KeyboardInputGateway _gateway;
  final int controlVirtualKey;
  final Duration gap;

  Future<void> inject(int virtualKey) async {
    final chord = <KeyboardStroke>[
      KeyboardStroke(virtualKey: controlVirtualKey, isKeyUp: false),
      KeyboardStroke(virtualKey: virtualKey, isKeyUp: false),
      KeyboardStroke(virtualKey: virtualKey, isKeyUp: true),
      KeyboardStroke(virtualKey: controlVirtualKey, isKeyUp: true),
    ];
    try {
      for (var index = 0; index < chord.length; index++) {
        sendKeyboardStrokesChecked(_gateway, [chord[index]]);
        if (index < chord.length - 1 && gap > Duration.zero) {
          await Future<void>.delayed(gap);
        }
      }
    } on PartialKeyboardInjectionException {
      releaseKeyboardStrokesBestEffort(_gateway, [
        KeyboardStroke(virtualKey: virtualKey, isKeyUp: true),
        KeyboardStroke(virtualKey: controlVirtualKey, isKeyUp: true),
      ]);
      rethrow;
    }
  }
}
