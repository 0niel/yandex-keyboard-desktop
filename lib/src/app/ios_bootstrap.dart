import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_state.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/data/file_settings_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/noop_hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/ios/ios_keyboard_settings_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/settings/text_assistant_settings_applier.dart';

Future<void> bootstrapIos() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDirectory = await getApplicationSupportDirectory();
  final repository = FileSettingsRepository(
    file: File('${supportDirectory.path}/settings.json'),
  );
  final policyProvider = MutableTextAssistantRuntimePolicyProvider();
  const gateway = MethodChannelIosKeyboardSettingsGateway();
  final controller = SettingsController(
    repository: repository,
    hotkeyRegistrar: const NoOpHotkeyRegistrar(),
    platform: ShortcutPlatform.ios,
    onShortcutTriggered: (_) {},
    runtimeApplier: CompositeSettingsRuntimeApplier([
      TextAssistantSettingsApplier(policyProvider: policyProvider),
      const IosKeyboardSettingsApplier(gateway),
    ]),
    draftPrivacyApplier:
        TextAssistantSettingsApplier(policyProvider: policyProvider),
  );
  await controller.initialize();
  runApp(BlocProvider.value(
    value: controller,
    child: const IosHostApp(gateway: gateway),
  ));
}

class IosHostApp extends StatelessWidget {
  const IosHostApp({super.key, required this.gateway});

  final IosKeyboardSettingsGateway gateway;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsController, SettingsState>(
      builder: (context, state) {
        final settings = state.draft ?? AppSettings.defaults();
        return CupertinoApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: settings.locale == 'system' ? null : Locale(settings.locale),
          theme: CupertinoThemeData(
            brightness: switch (settings.theme) {
              AppThemePreference.system => null,
              AppThemePreference.light => Brightness.light,
              AppThemePreference.dark => Brightness.dark,
            },
            primaryColor: const Color(0xFFFF0032),
            scaffoldBackgroundColor: CupertinoColors.systemGroupedBackground,
          ),
          home: IosKeyboardSettingsPage(gateway: gateway),
        );
      },
    );
  }
}

class IosKeyboardSettingsPage extends StatefulWidget {
  const IosKeyboardSettingsPage({super.key, required this.gateway});

  final IosKeyboardSettingsGateway gateway;

  @override
  State<IosKeyboardSettingsPage> createState() =>
      _IosKeyboardSettingsPageState();
}

class _IosKeyboardSettingsPageState extends State<IosKeyboardSettingsPage> {
  static const _timeoutOptions = [
    1000,
    5000,
    10000,
    15000,
    30000,
    60000,
    120000,
  ];

  bool? _appGroupAvailable;

  @override
  void initState() {
    super.initState();
    _refreshCapabilities();
  }

  Future<void> _refreshCapabilities() async {
    try {
      final capabilities = await widget.gateway.capabilities();
      if (mounted) {
        setState(() {
          _appGroupAvailable = capabilities['appGroupAvailable'] == true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _appGroupAvailable = false);
    }
  }

  Future<void> _selectTimeout(int currentValue) async {
    final strings = AppLocalizations.of(context)!;
    final selected = await showCupertinoModalPopup<int>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(strings.requestTimeout),
        message: Text(strings.iosKeyboardTimeoutDescription),
        actions: [
          for (final value in _timeoutOptions)
            CupertinoActionSheetAction(
              isDefaultAction: value == currentValue,
              onPressed: () => Navigator.of(context).pop(value),
              child: Text(strings.secondsShort(value ~/ 1000)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
      ),
    );
    if (selected != null && mounted) {
      context.read<SettingsController>().updateGeneral(
            requestTimeoutMilliseconds: selected,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(strings.iosKeyboardTitle),
      ),
      child: SafeArea(
        bottom: false,
        child: BlocBuilder<SettingsController, SettingsState>(
          builder: (context, state) {
            final settings = state.draft;
            if (settings == null) {
              return const _IosSettingsSkeleton();
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _HeroCard(
                  title: strings.iosKeyboardHeroTitle,
                  description: strings.iosKeyboardHeroDescription,
                  appGroupAvailable: _appGroupAvailable,
                ),
                CupertinoFormSection.insetGrouped(
                  header: Text(strings.iosKeyboardSetup),
                  footer: Text(strings.iosKeyboardSetupFootnote),
                  children: [
                    _InstructionRow(
                      number: '1',
                      text: strings.iosKeyboardSetupStepOne,
                    ),
                    _InstructionRow(
                      number: '2',
                      text: strings.iosKeyboardSetupStepTwo,
                    ),
                    _InstructionRow(
                      number: '3',
                      text: strings.iosKeyboardSetupStepThree,
                    ),
                  ],
                ),
                CupertinoFormSection.insetGrouped(
                  header: Text(strings.appearance),
                  children: [
                    _IosAdaptiveControlRow(
                      label: strings.theme,
                      control:
                          CupertinoSlidingSegmentedControl<AppThemePreference>(
                        groupValue: settings.theme,
                        children: {
                          AppThemePreference.system:
                              Text(strings.systemDefault),
                          AppThemePreference.light: Text(strings.lightTheme),
                          AppThemePreference.dark: Text(strings.darkTheme),
                        },
                        onValueChanged: (value) {
                          if (value != null) {
                            context
                                .read<SettingsController>()
                                .updateGeneral(theme: value);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                CupertinoFormSection.insetGrouped(
                  header: Text(strings.behavior),
                  footer: Text(
                    '${strings.iosKeyboardTransactionDescription}\n\n'
                    '${strings.iosKeyboardNoRetryDescription}',
                  ),
                  children: [
                    _IosAdaptiveControlRow(
                      label: strings.defaultAction,
                      control: CupertinoSlidingSegmentedControl<ShortcutAction>(
                        groupValue: settings.defaultAction,
                        children: {
                          ShortcutAction.rewrite: Text(strings.improve),
                          ShortcutAction.fix: Text(strings.fix),
                          ShortcutAction.emojify: Text(strings.emojify),
                        },
                        onValueChanged: (value) {
                          if (value != null) {
                            context
                                .read<SettingsController>()
                                .updateGeneral(defaultAction: value);
                          }
                        },
                      ),
                    ),
                    _IosAdaptiveControlRow(
                      label: strings.language,
                      control: CupertinoSlidingSegmentedControl<String>(
                        groupValue: settings.locale,
                        children: {
                          'system': Text(strings.systemDefault),
                          'en': const Text('English'),
                          'ru': const Text('Русский'),
                        },
                        onValueChanged: (value) {
                          if (value != null) {
                            context
                                .read<SettingsController>()
                                .updateGeneral(locale: value);
                          }
                        },
                      ),
                    ),
                    _IosAdaptiveControlRow(
                      label: strings.requestTimeout,
                      control: CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        onPressed: () => _selectTimeout(
                          settings.requestTimeoutMilliseconds,
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(strings.secondsShort(
                            settings.requestTimeoutMilliseconds ~/ 1000,
                          )),
                        ),
                      ),
                    ),
                  ],
                ),
                CupertinoFormSection.insetGrouped(
                  header: Text(strings.keyboardShortcuts),
                  footer: Text(strings.iosKeyboardShortcutsDescription),
                  children: [
                    CupertinoFormRow(
                      prefix: const Icon(CupertinoIcons.keyboard),
                      child: Text(strings.iosKeyboardActionBar),
                    ),
                  ],
                ),
                CupertinoFormSection.insetGrouped(
                  header: Text(strings.privacySettings),
                  children: [
                    CupertinoFormRow(
                      prefix: const Icon(CupertinoIcons.lock_shield),
                      child: Text(strings.iosKeyboardPrivacyDescription),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: SizedBox(
                    height: 50,
                    child: CupertinoButton.filled(
                      onPressed: state.hasBlockingIssues ||
                              state.stage == SettingsStage.saving ||
                              !state.isDirty
                          ? null
                          : () async {
                              await context.read<SettingsController>().save();
                              await _refreshCapabilities();
                            },
                      child: Text(
                        state.stage == SettingsStage.saving
                            ? strings.saving
                            : strings.save,
                      ),
                    ),
                  ),
                ),
                if (state.errorCode != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                    child: Text(
                      strings.iosKeyboardSyncError,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: CupertinoColors.systemRed),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _IosAdaptiveControlRow extends StatelessWidget {
  const _IosAdaptiveControlRow({
    required this.label,
    required this.control,
  });

  final String label;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scaledBody = MediaQuery.textScalerOf(context).scale(17);
          final stacked = constraints.maxWidth < 520 || scaledBody > 20;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(label),
                const SizedBox(height: 10),
                control,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: Text(label)),
              const SizedBox(width: 16),
              Flexible(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: control,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.title,
    required this.description,
    required this.appGroupAvailable,
  });

  final String title;
  final String description;
  final bool? appGroupAvailable;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 20, 20, 4),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Image.asset(
              'assets/brand/app_icon.png',
              width: 44,
              height: 44,
              excludeFromSemantics: true,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            style: const TextStyle(
              color: CupertinoColors.white,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(
              color: Color(0xE6FFFFFF),
              fontSize: 15,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          AnimatedSwitcher(
            duration: MediaQuery.maybeOf(context)?.disableAnimations == true
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: Row(
              key: ValueKey(appGroupAvailable),
              children: [
                Icon(
                  switch (appGroupAvailable) {
                    null => CupertinoIcons.ellipsis_circle_fill,
                    false => CupertinoIcons.exclamationmark_circle_fill,
                    true => CupertinoIcons.check_mark_circled_solid,
                  },
                  color: switch (appGroupAvailable) {
                    null => CupertinoColors.systemGrey3,
                    false => CupertinoColors.systemYellow,
                    true => CupertinoColors.systemGreen,
                  },
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    switch (appGroupAvailable) {
                      null => strings.iosKeyboardSyncChecking,
                      false => strings.iosKeyboardSyncUnavailable,
                      true => strings.iosKeyboardSyncReady,
                    },
                    style: const TextStyle(
                      color: CupertinoColors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InstructionRow extends StatelessWidget {
  const _InstructionRow({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return CupertinoFormRow(
      prefix: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: Color(0xFFFF0032),
          shape: BoxShape.circle,
        ),
        child: Text(
          number,
          style: const TextStyle(
            color: CupertinoColors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      child: Text(text),
    );
  }
}

class _IosSettingsSkeleton extends StatelessWidget {
  const _IosSettingsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: 4,
      itemBuilder: (context, index) => Container(
        height: index == 0 ? 180 : 72,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: CupertinoColors.systemFill.resolveFrom(context),
          borderRadius: BorderRadius.circular(18),
        ),
      ),
    );
  }
}
