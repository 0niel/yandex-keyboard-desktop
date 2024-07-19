import 'dart:convert';
import 'dart:io';

Future<Map<String, dynamic>> loadConfig() async {
  final configFile = File('config.json');
  if (!configFile.existsSync()) {
    final defaultConfig = {
      'hotkey': {
        'key': 'R',
        'modifiers': ['Control']
      },
      'autostart': true
    };
    await configFile.writeAsString(jsonEncode(defaultConfig));
    return defaultConfig;
  }
  final configContent = await configFile.readAsString();
  return jsonDecode(configContent);
}
