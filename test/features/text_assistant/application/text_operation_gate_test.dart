import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_operation_gate.dart';

void main() {
  test('admits only one target-capture operation at a time', () {
    final gate = TextOperationGate();
    final first = gate.tryAcquire();

    expect(first, isNotNull);
    expect(gate.isActive, isTrue);
    expect(gate.tryAcquire(), isNull);

    first!.release();
    expect(gate.isActive, isFalse);
    expect(gate.tryAcquire(), isNotNull);
  });

  test('stale permits cannot release a newer generation', () {
    final gate = TextOperationGate();
    final stale = gate.tryAcquire()!;
    gate.reset();
    final current = gate.tryAcquire()!;

    stale.release();
    expect(gate.isActive, isTrue);

    current.release();
    expect(gate.isActive, isFalse);
  });
}
