import 'dart:io';

class DiagnosticLog {
  DiagnosticLog._();

  static final DiagnosticLog instance = DiagnosticLog._();

  File? _file;

  void start(String filePath) {
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '=== session ${DateTime.now().toIso8601String()} ===\n',
      );
      _file = file;
    } catch (_) {
      _file = null;
    }
  }

  void write(String message) {
    final file = _file;
    if (file == null) return;
    try {
      file.writeAsStringSync(
        '${DateTime.now().toIso8601String()}  $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }
}

void diag(String message) => DiagnosticLog.instance.write(message);
