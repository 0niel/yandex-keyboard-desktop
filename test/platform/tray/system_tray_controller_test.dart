import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/tray/system_tray_controller.dart';

void main() {
  test('serializes native publications so the newest locale finishes last',
      () async {
    final calls = <String>[];
    final firstPublication = Completer<void>();
    final publisher = SerialTrayMenuPublisher((show, settings, exit) async {
      calls.add(show);
      if (show == 'Show') await firstPublication.future;
    });

    final english = publisher.publish('Show', 'Settings', 'Exit');
    final russian = publisher.publish('Показать', 'Настройки', 'Выход');

    await Future<void>.delayed(Duration.zero);
    expect(calls, ['Show']);
    firstPublication.complete();
    await Future.wait([english, russian]);
    expect(calls, ['Show', 'Показать']);
  });

  test('continues with the newest publication after a native failure',
      () async {
    final calls = <String>[];
    final publisher = SerialTrayMenuPublisher((show, settings, exit) async {
      calls.add(show);
      if (show == 'Show') throw StateError('native tray unavailable');
    });

    await expectLater(
      publisher.publish('Show', 'Settings', 'Exit'),
      throwsStateError,
    );
    await publisher.publish('Показать', 'Настройки', 'Выход');

    expect(calls, ['Show', 'Показать']);
  });
}
