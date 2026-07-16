import 'package:equatable/equatable.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';

enum AppThemePreference { system, light, dark }

enum ClipboardPolicy { restoreOriginal, keepReplacement }

final class AppSettings extends Equatable {
  AppSettings({
    required this.schemaVersion,
    required this.locale,
    required this.theme,
    required this.launchAtStartup,
    required List<KeyBindingProfile> profiles,
    required this.activeProfileId,
    required this.defaultAction,
    required this.clipboardPolicy,
    required this.requestTimeoutMilliseconds,
    required this.retryAttempts,
    required this.historyEnabled,
    required this.diagnosticsEnabled,
  }) : profiles = List.unmodifiable(profiles) {
    final profileIds = profiles.map((profile) => profile.id).toSet();
    if (profiles.isEmpty ||
        profileIds.length != profiles.length ||
        !profiles.any((profile) => profile.id == activeProfileId)) {
      throw const FormatException('Active keybinding profile is missing.');
    }
    if (requestTimeoutMilliseconds < 1000 ||
        requestTimeoutMilliseconds > 120000 ||
        retryAttempts < 0 ||
        retryAttempts > 8 ||
        defaultAction == ShortcutAction.showOverlay) {
      throw const FormatException('Invalid runtime policy settings.');
    }
  }

  static const currentSchemaVersion = 3;

  final int schemaVersion;
  final String locale;
  final AppThemePreference theme;
  final bool launchAtStartup;
  final List<KeyBindingProfile> profiles;
  final String activeProfileId;
  final ShortcutAction defaultAction;
  final ClipboardPolicy clipboardPolicy;
  final int requestTimeoutMilliseconds;
  final int retryAttempts;
  final bool historyEnabled;
  final bool diagnosticsEnabled;

  KeyBindingProfile get activeProfile =>
      profiles.firstWhere((profile) => profile.id == activeProfileId);

  factory AppSettings.defaults() {
    final profile = KeyBindingProfile.defaults();
    return AppSettings(
      schemaVersion: currentSchemaVersion,
      locale: 'system',
      theme: AppThemePreference.system,
      launchAtStartup: false,
      profiles: [profile],
      activeProfileId: profile.id,
      defaultAction: ShortcutAction.rewrite,
      clipboardPolicy: ClipboardPolicy.restoreOriginal,
      requestTimeoutMilliseconds: 15000,
      retryAttempts: 2,
      historyEnabled: false,
      diagnosticsEnabled: false,
    );
  }

  AppSettings copyWith({
    String? locale,
    AppThemePreference? theme,
    bool? launchAtStartup,
    List<KeyBindingProfile>? profiles,
    String? activeProfileId,
    ShortcutAction? defaultAction,
    ClipboardPolicy? clipboardPolicy,
    int? requestTimeoutMilliseconds,
    int? retryAttempts,
    bool? historyEnabled,
    bool? diagnosticsEnabled,
  }) =>
      AppSettings(
        schemaVersion: currentSchemaVersion,
        locale: locale ?? this.locale,
        theme: theme ?? this.theme,
        launchAtStartup: launchAtStartup ?? this.launchAtStartup,
        profiles: profiles ?? this.profiles,
        activeProfileId: activeProfileId ?? this.activeProfileId,
        defaultAction: defaultAction ?? this.defaultAction,
        clipboardPolicy: clipboardPolicy ?? this.clipboardPolicy,
        requestTimeoutMilliseconds:
            requestTimeoutMilliseconds ?? this.requestTimeoutMilliseconds,
        retryAttempts: retryAttempts ?? this.retryAttempts,
        historyEnabled: historyEnabled ?? this.historyEnabled,
        diagnosticsEnabled: diagnosticsEnabled ?? this.diagnosticsEnabled,
      );

  Map<String, Object> toJson() => {
        'schemaVersion': currentSchemaVersion,
        'locale': locale,
        'theme': theme.name,
        'launchAtStartup': launchAtStartup,
        'profiles': profiles.map((profile) => profile.toJson()).toList(),
        'activeProfileId': activeProfileId,
        'defaultAction': defaultAction.name,
        'clipboardPolicy': clipboardPolicy.name,
        'requestTimeoutMilliseconds': requestTimeoutMilliseconds,
        'retryAttempts': retryAttempts,
        'historyEnabled': historyEnabled,
        'diagnosticsEnabled': diagnosticsEnabled,
      };

  @override
  List<Object?> get props => [
        schemaVersion,
        locale,
        theme,
        launchAtStartup,
        profiles,
        activeProfileId,
        defaultAction,
        clipboardPolicy,
        requestTimeoutMilliseconds,
        retryAttempts,
        historyEnabled,
        diagnosticsEnabled,
      ];
}

final class AppSettingsCodec {
  const AppSettingsCodec();

  AppSettings decode(Map<String, dynamic> json) {
    final schema = json['schemaVersion'];
    if (schema != AppSettings.currentSchemaVersion) {
      throw UnsupportedSettingsVersionException(schema);
    }
    final rawProfiles = json['profiles'];
    if (rawProfiles is! List<dynamic>) {
      throw const FormatException('Invalid settings profiles.');
    }
    final profiles = rawProfiles.map((value) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid settings profile.');
      }
      return KeyBindingProfile.fromJson(value);
    }).toList();
    final locale = _readString(json, 'locale');
    if (!const {'system', 'en', 'ru'}.contains(locale)) {
      throw const FormatException('Invalid settings locale.');
    }
    return AppSettings(
      schemaVersion: AppSettings.currentSchemaVersion,
      locale: locale,
      theme: _readEnum(json, 'theme', AppThemePreference.values),
      launchAtStartup: _readBool(json, 'launchAtStartup'),
      profiles: profiles,
      activeProfileId: _readString(json, 'activeProfileId'),
      defaultAction: _readTextAction(json, 'defaultAction'),
      clipboardPolicy:
          _readEnum(json, 'clipboardPolicy', ClipboardPolicy.values),
      requestTimeoutMilliseconds: _readInt(json, 'requestTimeoutMilliseconds'),
      retryAttempts: _readInt(json, 'retryAttempts'),
      historyEnabled: _readBool(json, 'historyEnabled'),
      diagnosticsEnabled: _readBool(json, 'diagnosticsEnabled'),
    );
  }

  String _readString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Invalid settings field: $key.');
    }
    return value;
  }

  bool _readBool(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! bool) {
      throw FormatException('Invalid settings field: $key.');
    }
    return value;
  }

  int _readInt(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! int) {
      throw FormatException('Invalid settings field: $key.');
    }
    return value;
  }

  T _readEnum<T extends Enum>(
    Map<String, dynamic> json,
    String key,
    List<T> values,
  ) {
    final raw = json[key];
    for (final value in values) {
      if (value.name == raw) {
        return value;
      }
    }
    throw FormatException('Invalid settings field: $key.');
  }

  ShortcutAction _readTextAction(
    Map<String, dynamic> json,
    String key,
  ) =>
      switch (json[key]) {
        'emojify' => ShortcutAction.emojify,
        'fix' => ShortcutAction.fix,
        'rewrite' => ShortcutAction.rewrite,
        _ => throw FormatException('Invalid settings field: $key.'),
      };
}

final class UnsupportedSettingsVersionException implements Exception {
  const UnsupportedSettingsVersionException(this.version);

  final Object? version;

  @override
  String toString() => 'Unsupported settings schema version: $version';
}
