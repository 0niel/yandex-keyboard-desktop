import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_surface.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_state.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/general_settings_page.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/keyboard_settings_page.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/privacy_settings_page.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_runtime_state.dart';

export 'keyboard_settings_page.dart' show KeyChordRecorderDialog;

class SettingsWindow extends StatefulWidget {
  const SettingsWindow({
    super.key,
    required this.onSaved,
    this.shortcutsAvailable = true,
    this.manualClipboardMode = false,
    this.hotkeyRuntimeState,
    this.onConfigureShortcuts,
    this.onRetryShortcuts,
    this.minimizeOnClose = false,
    this.onClosed,
  });

  final VoidCallback onSaved;
  final bool shortcutsAvailable;
  final bool manualClipboardMode;
  final HotkeyRuntimeState? hotkeyRuntimeState;
  final VoidCallback? onConfigureShortcuts;
  final VoidCallback? onRetryShortcuts;
  final bool minimizeOnClose;
  final VoidCallback? onClosed;

  @override
  State<SettingsWindow> createState() => SettingsWindowState();
}

class SettingsWindowState extends State<SettingsWindow> {
  var _section = 0;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: AppColors.canvas(context),
          child: Column(
            children: [
              DragToMoveArea(
                child: SizedBox(
                  height: 44,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: 14,
                      end: 4,
                    ),
                    child: Row(
                      children: [
                        const BrandMark(size: 24),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            strings.settingsTitle,
                            style: AppTextStyles.label(context),
                          ),
                        ),
                        AppIconButton(
                          label: strings.dismiss,
                          icon: LucideIcons.x,
                          onPressed: _close,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: BlocBuilder<SettingsController, SettingsState>(
                  builder: (context, state) {
                    final settings = state.draft;
                    if (settings == null) {
                      return Center(
                        child: Text(errorText(strings, state.errorCode)),
                      );
                    }
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final compact = constraints.maxWidth < 720;
                        final navigation = _SettingsNavigation(
                          section: _section,
                          horizontal: compact,
                          onSelected: (value) =>
                              setState(() => _section = value),
                        );
                        final page = AppSwap(
                          child: KeyedSubtree(
                            key: ValueKey(_section),
                            child: switch (_section) {
                              0 => GeneralSettingsPage(settings: settings),
                              1 => KeyboardSettingsPage(
                                  settings: settings,
                                  shortcutsAvailable: widget.shortcutsAvailable,
                                  hotkeyRuntimeState: widget.hotkeyRuntimeState,
                                  onConfigureShortcuts:
                                      widget.onConfigureShortcuts,
                                  onRetryShortcuts: widget.onRetryShortcuts,
                                ),
                              _ => PrivacySettingsPage(
                                  settings: settings,
                                  manualClipboardMode:
                                      widget.manualClipboardMode,
                                ),
                            },
                          ),
                        );
                        return Column(
                          children: [
                            Expanded(
                              child: compact
                                  ? Column(
                                      children: [
                                        navigation,
                                        Expanded(child: page),
                                      ],
                                    )
                                  : Row(
                                      children: [
                                        SizedBox(width: 176, child: navigation),
                                        Expanded(child: page),
                                      ],
                                    ),
                            ),
                            _SettingsFooter(
                              state: state,
                              onSaved: widget.onSaved,
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> confirmDiscardIfNeeded() async {
    final controller = context.read<SettingsController>();
    if (controller.state.isDirty) {
      final strings = AppLocalizations.of(context)!;
      final discard = await showAppDialog<bool>(
        context: context,
        barrierLabel: strings.dismiss,
        builder: (context) => AppDialog(
          title: strings.unsavedChanges,
          content: Text(strings.unsavedChangesDescription),
          actions: [
            AppButton(
              label: strings.cancel,
              onPressed: () => Navigator.pop(context, false),
            ),
            AppButton(
              label: strings.discard,
              kind: AppButtonKind.primary,
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
      );
      if (discard != true) return false;
      controller.discardChanges();
    }
    return true;
  }

  Future<void> _close() async {
    if (!await confirmDiscardIfNeeded()) return;
    if (widget.minimizeOnClose) {
      widget.onClosed?.call();
      await windowManager.minimize();
    } else {
      await windowManager.hide();
    }
  }
}

class _SettingsNavigation extends StatelessWidget {
  const _SettingsNavigation({
    required this.section,
    required this.horizontal,
    required this.onSelected,
  });

  final int section;
  final bool horizontal;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    final items = [
      (LucideIcons.slidersHorizontal, strings.generalSettings, 'general'),
      (LucideIcons.keyboard, strings.keyboardShortcuts, 'keyboard'),
      (LucideIcons.shield, strings.privacySettings, 'privacy'),
    ];
    final children = [
      for (var index = 0; index < items.length; index++)
        _NavButton(
          key: ValueKey('settings-navigation-${items[index].$3}'),
          icon: items[index].$1,
          label: items[index].$2,
          selected: section == index,
          onPressed: () => onSelected(index),
        ),
    ];
    return ColoredBox(
      color: AppColors.sidebar(context),
      child: Padding(
        padding: horizontal
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
            : const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: horizontal
            ? SizedBox(
                height: 44,
                child: Row(
                  children: [
                    for (final child in children) Expanded(child: child)
                  ],
                ),
              )
            : Column(children: children),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        label: label,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: AppPressable(
            onPressed: onPressed,
            semanticLabel: label,
            backgroundColor:
                selected ? AppColors.surface(context) : const Color(0x00000000),
            hoverColor: AppColors.textPrimary(context).withValues(alpha: 0.08),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: selected
                      ? AppColors.textPrimary(context)
                      : AppColors.textSecondary(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.label(context).copyWith(
                      color: selected
                          ? AppColors.textPrimary(context)
                          : AppColors.textSecondary(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _SettingsFooter extends StatelessWidget {
  const _SettingsFooter({required this.state, required this.onSaved});

  final SettingsState state;
  final VoidCallback onSaved;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    final saving = state.stage == SettingsStage.saving;
    return ColoredBox(
      color: AppColors.surface(context),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 600 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.3;
              final error = state.errorCode == null
                  ? null
                  : Text(
                      errorText(strings, state.errorCode),
                      maxLines: compact ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.danger,
                        fontSize: 12,
                      ),
                    );
              final actions = Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: [
                  AppButton(
                    label: strings.discard,
                    onPressed: state.isDirty && !saving
                        ? context.read<SettingsController>().discardChanges
                        : null,
                  ),
                  AppButton(
                    label: saving ? strings.saving : strings.save,
                    kind: AppButtonKind.primary,
                    onPressed:
                        state.isDirty && !state.hasBlockingIssues && !saving
                            ? () async {
                                if (await context
                                    .read<SettingsController>()
                                    .save()) {
                                  onSaved();
                                }
                              }
                            : null,
                  ),
                ],
              );
              if (compact) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (error != null) ...[
                      error,
                      const SizedBox(height: 4),
                    ],
                    Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: actions),
                  ],
                );
              }
              return Row(
                children: [
                  if (error != null) Expanded(child: error) else const Spacer(),
                  actions,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

String errorText(AppLocalizations strings, String? code) => switch (code) {
      'settings_unsupported_version' => strings.settingsUnsupportedVersion,
      'settings_load_failed' => strings.settingsLoadFailed,
      'settings_save_failed' => strings.settingsSaveFailed,
      'settings_reconciliation_failed' => strings.settingsReconciliationFailed,
      'settings_runtime_apply_failed' => strings.settingsRuntimeApplyFailed,
      'settings_initialization_rollback_failed' =>
        strings.settingsInitializationRollbackFailed,
      'keybinding_registration_rollback_failed' => strings.hotkeyRollbackFailed,
      'keybinding_registration_failed' => strings.hotkeyRegistrationFailed,
      'wayland_global_shortcuts_unavailable' =>
        strings.portalShortcutsUnavailable,
      'wayland_global_shortcuts_cancelled' ||
      'wayland_global_shortcuts_partial_bind' =>
        strings.portalShortcutsApprovalRequired,
      'wayland_global_shortcuts_capability_failed' ||
      'wayland_global_shortcuts_malformed_response' ||
      'wayland_global_shortcuts_bind_failed' ||
      'wayland_global_shortcuts_registration_failed' =>
        strings.portalShortcutsFailed,
      _ => strings.settingsUnknownError,
    };
