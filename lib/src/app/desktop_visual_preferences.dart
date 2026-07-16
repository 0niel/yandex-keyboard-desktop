import 'package:flutter/widgets.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';

Brightness resolveDesktopBrightness({
  required AppThemePreference preference,
  required Brightness systemBrightness,
}) =>
    switch (preference) {
      AppThemePreference.light => Brightness.light,
      AppThemePreference.dark => Brightness.dark,
      AppThemePreference.system => systemBrightness,
    };

Locale resolveDesktopLocale({
  required String configuredLocale,
  required Locale systemLocale,
}) {
  if (configuredLocale == 'en_XA') return const Locale('en', 'XA');
  if (configuredLocale == 'en' || configuredLocale == 'ru') {
    return Locale(configuredLocale);
  }
  return systemLocale.languageCode == 'ru'
      ? const Locale('ru')
      : const Locale('en');
}
