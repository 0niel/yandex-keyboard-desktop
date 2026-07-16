import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/windows_process_job.dart';

void main() {
  test('closing the job terminates its child process', () async {
    if (!Platform.isWindows) return;
    final process = await Process.start(
      'powershell.exe',
      const <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Start-Sleep -Seconds 30',
      ],
    );
    try {
      final job = WindowsProcessJob.attach(process.pid);
      job.close();

      await expectLater(
        process.exitCode.timeout(const Duration(seconds: 3)),
        completes,
      );
    } finally {
      process.kill();
    }
  });
}
