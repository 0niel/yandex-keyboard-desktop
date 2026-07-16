import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/direct_selection_reader.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/uia/win32_uia_process_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/uia/windows_uia_gateway.dart';

void main() {
  const target = DirectSelectionTarget(windowHandle: 42, processId: 4242);

  test('accepts one token-authenticated bounded helper response', () async {
    if (!Platform.isWindows) return;
    const script = r'''
$client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', [int]$args[1])
$stream = $client.GetStream()
$encoding = [System.Text.UTF8Encoding]::new($false)
$writer = [System.IO.StreamWriter]::new($stream, $encoding)
$payload = @{
  status = 'success'
  windowHandle = [int64]$args[2]
  processId = [int]$args[3]
  runtimeId = @(42, 7, 9)
  token = $env:YKD_UIA_HELPER_TOKEN
} | ConvertTo-Json -Compress
$writer.Write($payload)
$writer.Flush()
$writer.Dispose()
$client.Dispose()
''';
    final tempDirectory = await Directory.systemTemp.createTemp(
      'yandex-keyboard-uia-test-',
    );
    final scriptFile = File('${tempDirectory.path}/helper.ps1');
    await scriptFile.writeAsString(script, flush: true);
    try {
      final gateway = Win32UiaProcessGateway(
        providerTimeout: const Duration(seconds: 15),
        helperExecutable: 'powershell.exe',
        helperArgumentsPrefix: <String>[
          '-NoProfile',
          '-NonInteractive',
          '-File',
          scriptFile.path,
        ],
      );

      final probe = await gateway.inspectFocusedTarget(target);

      expect(probe.status, WindowsUiaProbeStatus.success);
      expect(probe.identity?.windowHandle, 42);
      expect(probe.identity?.processId, 4242);
      expect(probe.identity?.runtimeId, [42, 7, 9]);
    } finally {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('terminates an unresponsive helper at the provider timeout', () async {
    if (!Platform.isWindows) return;
    final stopwatch = Stopwatch()..start();
    final gateway = Win32UiaProcessGateway(
      providerTimeout: const Duration(milliseconds: 150),
      helperExecutable: 'powershell.exe',
      helperArgumentsPrefix: const <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Start-Sleep -Seconds 30',
      ],
    );

    final probe = await gateway.inspectFocusedTarget(target);
    stopwatch.stop();

    expect(probe.status, WindowsUiaProbeStatus.timeout);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
  });
}
