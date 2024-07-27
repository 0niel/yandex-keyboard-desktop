import 'dart:convert';
import 'dart:io';

class ConfigManager {
  static const String _configFilePath = 'config.json';

  static Future<Map<String, dynamic>> loadConfig() async {
    final configFile = File(_configFilePath);
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

  static Future<void> saveConfig(Map<String, dynamic> config) async {
    final configFile = File(_configFilePath);
    await configFile.writeAsString(jsonEncode(config));
  }
}
