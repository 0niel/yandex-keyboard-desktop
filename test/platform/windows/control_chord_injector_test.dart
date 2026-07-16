import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/control_chord_injector.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/keyboard_input_gateway.dart';

void main() {
  test('injects a balanced spaced control chord', () async {
    final gateway = _FakeKeyboardInputGateway([1, 1, 1, 1]);
    final injector = ControlChordInjector(
      gateway: gateway,
      controlVirtualKey: 0x11,
      gap: Duration.zero,
    );

    await injector.inject(0x43);

    expect(gateway.batches, hasLength(4));
    expect(
      gateway.batches
          .expand((batch) => batch)
          .map((stroke) => stroke.virtualKey),
      [0x11, 0x43, 0x43, 0x11],
    );
    expect(
      gateway.batches.expand((batch) => batch).map((stroke) => stroke.isKeyUp),
      [false, false, true, true],
    );
  });

  for (var failedStep = 0; failedStep < 4; failedStep++) {
    test('cleans up after injection step ${failedStep + 1} fails', () async {
      final gateway = _FakeKeyboardInputGateway([
        ...List<int>.filled(failedStep, 1),
        0,
        1,
        1,
      ]);
      final injector = ControlChordInjector(
        gateway: gateway,
        controlVirtualKey: 0x11,
        gap: Duration.zero,
      );

      await expectLater(
        injector.inject(0x56),
        throwsA(
          isA<PartialKeyboardInjectionException>()
              .having((error) => error.sent, 'sent', 0)
              .having((error) => error.expected, 'expected', 1),
        ),
      );

      expect(gateway.batches, hasLength(failedStep + 3));
      expect(
        gateway.batches
            .skip(failedStep + 1)
            .map((batch) => batch.single.virtualKey),
        [0x56, 0x11],
      );
      expect(
        gateway.batches
            .skip(failedStep + 1)
            .every((batch) => batch.single.isKeyUp),
        isTrue,
      );
    });
  }

  test('retries an individual key-up when cleanup is partial', () async {
    final gateway = _FakeKeyboardInputGateway([0, 0, 1, 1]);
    final injector = ControlChordInjector(
      gateway: gateway,
      controlVirtualKey: 0x11,
      gap: Duration.zero,
    );

    await expectLater(
      injector.inject(0x56),
      throwsA(isA<PartialKeyboardInjectionException>()),
    );

    expect(
      gateway.batches.skip(1).map((batch) => batch.single.virtualKey),
      [0x56, 0x56, 0x11],
    );
    expect(
      gateway.batches.skip(1).every((batch) => batch.single.isKeyUp),
      isTrue,
    );
  });

  test('rejects a partial modifier-release batch', () {
    final gateway = _FakeKeyboardInputGateway([1]);
    final strokes = [
      const KeyboardStroke(virtualKey: 0x10, isKeyUp: true),
      const KeyboardStroke(virtualKey: 0x11, isKeyUp: true),
    ];

    expect(
      () => sendKeyboardStrokesChecked(gateway, strokes),
      throwsA(
        isA<PartialKeyboardInjectionException>()
            .having((error) => error.sent, 'sent', 1)
            .having((error) => error.expected, 'expected', 2),
      ),
    );
  });
}

final class _FakeKeyboardInputGateway implements KeyboardInputGateway {
  _FakeKeyboardInputGateway(this.results);

  final List<int> results;
  final List<List<KeyboardStroke>> batches = [];

  @override
  int send(List<KeyboardStroke> strokes) {
    batches.add(List<KeyboardStroke>.of(strokes));
    return results.removeAt(0);
  }
}
