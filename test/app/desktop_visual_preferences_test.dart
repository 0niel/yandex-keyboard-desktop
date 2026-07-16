import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/app/desktop_visual_preferences.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';

void main() {
  test('explicit theme wins and system theme follows the dispatcher', () {
    expect(
      resolveDesktopBrightness(
        preference: AppThemePreference.dark,
        systemBrightness: Brightness.light,
      ),
      Brightness.dark,
    );
    expect(
      resolveDesktopBrightness(
        preference: AppThemePreference.system,
        systemBrightness: Brightness.dark,
      ),
      Brightness.dark,
    );
  });

  test('tray locale supports explicit, pseudo, and safe system fallback', () {
    expect(
      resolveDesktopLocale(
        configuredLocale: 'ru',
        systemLocale: const Locale('en'),
      ),
      const Locale('ru'),
    );
    expect(
      resolveDesktopLocale(
        configuredLocale: 'en_XA',
        systemLocale: const Locale('ru'),
      ),
      const Locale('en', 'XA'),
    );
    expect(
      resolveDesktopLocale(
        configuredLocale: 'system',
        systemLocale: const Locale('de'),
      ),
      const Locale('en'),
    );
  });
}
