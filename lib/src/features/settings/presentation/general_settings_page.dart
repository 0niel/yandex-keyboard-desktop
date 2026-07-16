import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/settings_widgets.dart';

const _repositoryUrl = 'https://github.com/0niel/yandex-keyboard-desktop';

class GeneralSettingsPage extends StatelessWidget {
  const GeneralSettingsPage({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    final controller = context.read<SettingsController>();
    return SettingsPageScroll(
      title: strings.generalSettings,
      description: strings.generalSettingsDescription,
      children: [
        SettingGroup(
          title: strings.appearance,
          children: [
            SettingRow(
              label: strings.theme,
              control: AppSelect<AppThemePreference>(
                value: settings.theme,
                items: {
                  AppThemePreference.system: strings.systemDefault,
                  AppThemePreference.light: strings.lightTheme,
                  AppThemePreference.dark: strings.darkTheme,
                },
                onChanged: (value) => controller.updateGeneral(theme: value),
              ),
            ),
            SettingRow(
              label: strings.language,
              control: AppSelect<String>(
                value: settings.locale,
                items: {
                  'system': strings.systemDefault,
                  'en': 'English',
                  'ru': 'Русский',
                },
                onChanged: (value) => controller.updateGeneral(locale: value),
              ),
            ),
          ],
        ),
        SettingGroup(
          title: strings.behavior,
          children: [
            SettingRow(
              label: strings.autostart,
              control: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: AppSwitch(
                  label: strings.autostart,
                  value: settings.launchAtStartup,
                  onChanged: (value) =>
                      controller.updateGeneral(launchAtStartup: value),
                ),
              ),
            ),
            SettingRow(
              label: strings.defaultAction,
              control: AppSelect<ShortcutAction>(
                value: settings.defaultAction,
                items: {
                  ShortcutAction.emojify: strings.emojifySelection,
                  ShortcutAction.rewrite: strings.rewriteSelection,
                  ShortcutAction.fix: strings.fixSelection,
                },
                onChanged: (value) =>
                    controller.updateGeneral(defaultAction: value),
              ),
            ),
          ],
        ),
        SettingGroup(
          title: strings.processing,
          children: [
            SettingRow(
              label: strings.requestTimeout,
              control: AppSelect<int>(
                value: settings.requestTimeoutMilliseconds,
                items: {
                  for (final value in const [
                    1000,
                    5000,
                    10000,
                    15000,
                    30000,
                    60000,
                    120000,
                  ])
                    value: '${value ~/ 1000} s',
                },
                onChanged: (value) => controller.updateGeneral(
                  requestTimeoutMilliseconds: value,
                ),
              ),
            ),
            SettingRow(
              label: strings.retryAttempts,
              control: AppSelect<int>(
                value: settings.retryAttempts,
                items: {
                  for (var value = 0; value <= 8; value++) value: '$value'
                },
                onChanged: (value) =>
                    controller.updateGeneral(retryAttempts: value),
              ),
            ),
          ],
        ),
        SettingGroup(
          title: strings.aboutSection,
          children: [
            SettingRow(
              label: strings.sourceCode,
              control: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: AppButton(
                  label: strings.openRepository,
                  compact: true,
                  onPressed: () => launchUrl(
                    Uri.parse(_repositoryUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
