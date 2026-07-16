import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:yandex_keyboard_desktop/src/platform/selection/direct_selection_reader.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/windows_process_job.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/uia/win32_uia_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/uia/windows_uia_gateway.dart';

const windowsUiaHelperArgument = '--yandex-keyboard-uia-helper';
const _helperTokenEnvironment = 'YKD_UIA_HELPER_TOKEN';
const _maximumHelperResponseBytes = 1024 * 1024;

final class Win32UiaProcessGateway implements WindowsUiaGateway {
  const Win32UiaProcessGateway({
    this.providerTimeout = const Duration(milliseconds: 1200),
    this.helperExecutable,
    this.helperArgumentsPrefix = const <String>[],
  });

  final Duration providerTimeout;
  final String? helperExecutable;
  final List<String> helperArgumentsPrefix;

  @override
  Future<WindowsUiaProbe> inspectFocusedTarget(
    DirectSelectionTarget target,
  ) =>
      _runProbe(target, includeSelection: false, maxTextLength: 0);

  @override
  Future<WindowsUiaProbe> readSelection(
    DirectSelectionTarget target, {
    required int maxTextLength,
  }) =>
      _runProbe(
        target,
        includeSelection: true,
        maxTextLength: maxTextLength,
      );

  Future<WindowsUiaProbe> _runProbe(
    DirectSelectionTarget target, {
    required bool includeSelection,
    required int maxTextLength,
  }) async {
    ServerSocket? server;
    Socket? socket;
    Process? helper;
    WindowsProcessJob? helperJob;
    try {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final token = _secureToken();
      helper = await Process.start(
        helperExecutable ?? Platform.resolvedExecutable,
        <String>[
          ...helperArgumentsPrefix,
          windowsUiaHelperArgument,
          server.port.toString(),
          target.windowHandle.toString(),
          target.processId.toString(),
          includeSelection ? '1' : '0',
          maxTextLength.toString(),
        ],
        environment: <String, String>{_helperTokenEnvironment: token},
        includeParentEnvironment: true,
        mode: ProcessStartMode.normal,
      );
      helperJob = WindowsProcessJob.attach(helper.pid);
      socket = await server.first.timeout(providerTimeout);
      final response = await _readBoundedResponse(socket).timeout(
        providerTimeout,
      );
      final decoded = jsonDecode(response);
      if (decoded is! Map<String, dynamic> || decoded['token'] != token) {
        return const WindowsUiaProbe(
          status: WindowsUiaProbeStatus.providerFailure,
        );
      }
      return decodeWindowsUiaProbeMessage(decoded);
    } on TimeoutException {
      return const WindowsUiaProbe(status: WindowsUiaProbeStatus.timeout);
    } catch (_) {
      return const WindowsUiaProbe(
        status: WindowsUiaProbeStatus.providerFailure,
      );
    } finally {
      socket?.destroy();
      await server?.close();
      helper?.kill();
      if (helper != null) {
        try {
          await helper.exitCode.timeout(const Duration(milliseconds: 250));
        } on TimeoutException {
          helper.kill(ProcessSignal.sigkill);
        }
      }
      helperJob?.close();
    }
  }
}

Future<bool> runWindowsUiaHelperIfRequested(List<String> arguments) async {
  if (arguments.isEmpty || arguments.first != windowsUiaHelperArgument) {
    return false;
  }
  if (!Platform.isWindows || arguments.length != 6) return true;

  final token = Platform.environment[_helperTokenEnvironment];
  final port = int.tryParse(arguments[1]);
  final windowHandle = int.tryParse(arguments[2]);
  final processId = int.tryParse(arguments[3]);
  final includeSelection = switch (arguments[4]) {
    '1' => true,
    '0' => false,
    _ => null,
  };
  final maxTextLength = int.tryParse(arguments[5]);
  if (token == null ||
      token.isEmpty ||
      port == null ||
      windowHandle == null ||
      processId == null ||
      includeSelection == null ||
      maxTextLength == null) {
    return true;
  }

  final response = await Isolate.run(
    () => runWin32UiaProbeSynchronously(
      expectedWindowHandle: windowHandle,
      expectedProcessId: processId,
      includeSelection: includeSelection,
      maxTextLength: maxTextLength,
    ),
  );
  response['token'] = token;
  try {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    socket.write(jsonEncode(response));
    await socket.flush();
    await socket.close();
  } catch (_) {}
  return true;
}

Future<String> _readBoundedResponse(Socket socket) async {
  final bytes = <int>[];
  await for (final chunk in socket) {
    if (bytes.length + chunk.length > _maximumHelperResponseBytes) {
      throw const FormatException('UIA helper response exceeded its limit.');
    }
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes);
}

String _secureToken() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var index = 0; index < 32; index++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
