import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app/diagnostic_log.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/shortcut_platform_context.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/settings_widgets.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_runtime_state.dart';

enum _ProfileAction { duplicate, rename, delete, import, export, reset }

class KeyboardSettingsPage extends StatelessWidget {
  const KeyboardSettingsPage({
    super.key,
    required this.settings,
    required this.shortcutsAvailable,
    required this.hotkeyRuntimeState,
    required this.onConfigureShortcuts,
    required this.onRetryShortcuts,
  });

  final AppSettings settings;
  final bool shortcutsAvailable;
  final HotkeyRuntimeState? hotkeyRuntimeState;
  final VoidCallback? onConfigureShortcuts;
  final VoidCallback? onRetryShortcuts;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    return SettingsPageScroll(
      title: strings.keyboardShortcuts,
      description: strings.keyboardShortcutsDescription,
      children: [
        if (hotkeyRuntimeState case final runtime?)
          _PortalStatus(
            state: runtime,
            onConfigure: onConfigureShortcuts,
            onRetry: onRetryShortcuts,
          ),
        if (!shortcutsAvailable)
          InlineNotice(
            icon: LucideIcons.keyboardOff,
            title: strings.manualShortcutsUnavailableTitle,
            description: strings.manualShortcutsUnavailableDescription,
          ),
        if (shortcutsAvailable) ...[
          _ProfileControls(settings: settings),
          for (final action in ShortcutAction.values)
            _ShortcutRow(
              action: action,
              chord: settings.activeProfile.bindings[action]!,
              actualTrigger: hotkeyRuntimeState
                  ?.bindings[action]?.actualTriggerDescription,
            ),
        ],
      ],
    );
  }
}

class _ProfileControls extends StatelessWidget {
  const _ProfileControls({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    final controller = context.read<SettingsController>();
    return SettingGroup(
      title: strings.shortcutProfiles,
      children: [
        Row(
          children: [
            Expanded(
              child: AppSelect<String>(
                value: settings.activeProfileId,
                items: {
                  for (final profile in settings.profiles)
                    profile.id: profile.id == 'default'
                        ? strings.defaultProfileName
                        : profile.name,
                },
                onChanged: controller.selectProfile,
              ),
            ),
            const SizedBox(width: 8),
            AppButton(
              label: strings.newProfile,
              onPressed: () => _createProfile(context),
              icon: LucideIcons.plus,
            ),
            AppIconButton(
              label: strings.more,
              icon: LucideIcons.ellipsis,
              onPressed: () => _showProfileActions(context),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showProfileActions(BuildContext context) async {
    final strings = AppLocalizations.of(context)!;
    final selected = await showAppDialog<_ProfileAction>(
      context: context,
      barrierLabel: strings.dismiss,
      builder: (dialogContext) => AppDialog(
        title: strings.shortcutProfiles,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry in <_ProfileAction, String>{
              _ProfileAction.duplicate: strings.duplicateProfile,
              _ProfileAction.rename: strings.renameProfile,
              _ProfileAction.delete: strings.deleteProfile,
              _ProfileAction.import: strings.importProfile,
              _ProfileAction.export: strings.exportProfile,
              _ProfileAction.reset: strings.resetProfile,
            }.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: AppButton(
                  label: entry.value,
                  onPressed: entry.key == _ProfileAction.delete &&
                          settings.profiles.length <= 1
                      ? null
                      : () => Navigator.pop(dialogContext, entry.key),
                ),
              ),
          ],
        ),
        actions: [
          AppButton(
            label: strings.cancel,
            onPressed: () => Navigator.pop(dialogContext),
          ),
        ],
      ),
    );
    if (selected != null && context.mounted) {
      await _performProfileAction(context, selected);
    }
  }

  Future<void> _createProfile(BuildContext context) async {
    final strings = AppLocalizations.of(context)!;
    final name = await askForProfileName(
      context,
      title: strings.newProfile,
      initialValue: strings.newProfileDefaultName,
    );
    if (name != null && context.mounted) {
      context.read<SettingsController>().createProfile(name);
    }
  }

  Future<void> _performProfileAction(
    BuildContext context,
    _ProfileAction action,
  ) async {
    final controller = context.read<SettingsController>();
    final strings = AppLocalizations.of(context)!;
    switch (action) {
      case _ProfileAction.duplicate:
        final active = controller.state.draft!.activeProfile;
        final name = await askForProfileName(
          context,
          title: strings.duplicateProfile,
          initialValue: '${active.name} ${strings.copySuffix}',
        );
        if (name != null && context.mounted) {
          controller.duplicateActiveProfile(name);
        }
      case _ProfileAction.rename:
        final name = await askForProfileName(
          context,
          title: strings.renameProfile,
          initialValue: controller.state.draft!.activeProfile.name,
        );
        if (name != null && context.mounted) {
          controller.renameActiveProfile(name);
        }
      case _ProfileAction.delete:
        controller.deleteActiveProfile();
      case _ProfileAction.import:
        await _importProfile(context);
      case _ProfileAction.export:
        await _exportProfile(context);
      case _ProfileAction.reset:
        controller.resetActiveProfile();
    }
  }

  Future<void> _importProfile(BuildContext context) async {
    final strings = AppLocalizations.of(context)!;
    var source = '';
    String? error;
    await showAppDialog<void>(
      context: context,
      barrierLabel: strings.dismiss,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AppDialog(
          title: strings.importProfile,
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(strings.importProfileDescription),
                const SizedBox(height: 12),
                AppTextField(
                  onChanged: (value) => source = value,
                  minLines: 8,
                  maxLines: 12,
                  hintText: '{ ... }',
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: AppColors.danger)),
                ],
              ],
            ),
          ),
          actions: [
            AppButton(
              label: strings.cancel,
              onPressed: () => Navigator.pop(dialogContext),
            ),
            AppButton(
              label: strings.importProfile,
              kind: AppButtonKind.primary,
              onPressed: () {
                try {
                  context.read<SettingsController>().importProfile(source);
                  Navigator.pop(dialogContext);
                } on FormatException {
                  setState(() => error = strings.invalidProfileImport);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportProfile(BuildContext context) async {
    final strings = AppLocalizations.of(context)!;
    final source = context.read<SettingsController>().exportActiveProfile();
    await showAppDialog<void>(
      context: context,
      barrierLabel: strings.dismiss,
      builder: (dialogContext) => AppDialog(
        title: strings.exportProfile,
        content: SizedBox(
          width: 500,
          child: AppTextField(
            initialValue: source,
            readOnly: true,
            minLines: 10,
            maxLines: 14,
          ),
        ),
        actions: [
          AppButton(
            label: strings.cancel,
            onPressed: () => Navigator.pop(dialogContext),
          ),
          AppButton(
            label: strings.copyToClipboard,
            icon: LucideIcons.copy,
            kind: AppButtonKind.primary,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: source));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
          ),
        ],
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.action,
    required this.chord,
    required this.actualTrigger,
  });

  final ShortcutAction action;
  final KeyChord chord;
  final String? actualTrigger;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    final controller = context.read<SettingsController>();
    final issues = controller.state.issues
        .where(
          (entry) =>
              entry.profileId == controller.state.draft!.activeProfileId &&
              entry.issue.action == action,
        )
        .toList();
    return SettingGroup(
      title: actionLabel(strings, action),
      children: [
        Row(
          children: [
            Icon(actionIcon(action), size: 19, color: AppColors.brand),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Builder(
                    builder: (buttonContext) => AppButton(
                      label: formatChord(chord),
                      onPressed: () async {
                        await controller.suspendGlobalHotkeys();
                        if (!buttonContext.mounted) {
                          await controller.resumeGlobalHotkeys();
                          return;
                        }
                        final next = await showAppDialog<KeyChord>(
                          context: buttonContext,
                          barrierLabel: strings.dismiss,
                          builder: (_) =>
                              KeyChordRecorderDialog(initial: chord),
                        );
                        await controller.resumeGlobalHotkeys();
                        if (next != null && buttonContext.mounted) {
                          controller.updateBinding(action, next);
                        }
                      },
                    ),
                  ),
                  if (actualTrigger != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      strings.portalShortcutsAssigned(actualTrigger!),
                      style: TextStyle(
                        color: AppColors.textSecondary(context),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            AppSwitch(
              label: actionLabel(strings, action),
              value: chord.enabled,
              onChanged: (value) => controller.updateBinding(
                action,
                chord.copyWith(enabled: value),
              ),
            ),
            AppIconButton(
              label: strings.resetShortcut,
              icon: LucideIcons.refreshCw,
              onPressed: () => controller.resetBinding(action),
            ),
          ],
        ),
        if (issues.isNotEmpty)
          for (final issue in issues)
            Text(
              issueLabel(strings, issue.issue.kind),
              style: const TextStyle(color: AppColors.danger, fontSize: 12),
            ),
      ],
    );
  }
}

class _PortalStatus extends StatelessWidget {
  const _PortalStatus({
    required this.state,
    required this.onConfigure,
    required this.onRetry,
  });

  final HotkeyRuntimeState state;
  final VoidCallback? onConfigure;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    final (icon, title, description) = switch (state.phase) {
      HotkeyRuntimePhase.active => (
          LucideIcons.circleCheck,
          strings.portalShortcutsActive,
          strings.portalShortcutsAssigned(
            state.bindings.values
                .map((binding) =>
                    binding.actualTriggerDescription ?? binding.desiredTrigger)
                .join(' · '),
          ),
        ),
      HotkeyRuntimePhase.binding => (
          LucideIcons.refreshCw,
          strings.portalShortcutsBinding,
          strings.portalShortcutsApprovalRequired,
        ),
      HotkeyRuntimePhase.revoked => (
          LucideIcons.rotateCcwKey,
          strings.portalShortcutsRevoked,
          strings.portalShortcutsApprovalRequired,
        ),
      HotkeyRuntimePhase.failed => (
          LucideIcons.triangleAlert,
          strings.portalShortcutsFailed,
          strings.portalShortcutsFailed,
        ),
      HotkeyRuntimePhase.unavailable => (
          LucideIcons.keyboardOff,
          strings.portalShortcutsUnavailable,
          strings.portalShortcutsUnavailable,
        ),
      _ => (
          LucideIcons.circlePause,
          strings.portalShortcutsInactive,
          strings.portalShortcutsApprovalRequired,
        ),
    };
    final retryable = state.phase == HotkeyRuntimePhase.revoked ||
        state.phase == HotkeyRuntimePhase.failed;
    return InlineNotice(
      icon: icon,
      title: title,
      description: description,
      action: retryable && onRetry != null
          ? AppButton(
              label: strings.portalShortcutsRetry,
              onPressed: onRetry,
            )
          : state.configureSupported && onConfigure != null
              ? AppButton(
                  label: strings.portalShortcutsConfigure,
                  onPressed: onConfigure,
                )
              : null,
    );
  }
}

class KeyChordRecorderDialog extends StatefulWidget {
  const KeyChordRecorderDialog({super.key, required this.initial});

  final KeyChord initial;

  @override
  State<KeyChordRecorderDialog> createState() => _KeyChordRecorderDialogState();
}

class _KeyChordRecorderDialogState extends State<KeyChordRecorderDialog> {
  KeyChord? _preview;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return true;
    diag('recorder key: ${event.logicalKey.keyLabel} '
        '(${event.physicalKey.debugName})');
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return true;
    }
    if (_isModifier(event.logicalKey)) return true;
    final key = _physicalKeyName(event.physicalKey);
    if (key == null) return true;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    setState(() {
      _preview = KeyChord(
        key: key,
        modifiers: {
          if (pressed.any(_isControl)) KeyModifier.control,
          if (pressed.any(_isAlt)) KeyModifier.alt,
          if (pressed.any(_isShift)) KeyModifier.shift,
          if (pressed.any(_isMeta)) KeyModifier.meta,
        },
      );
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    return AppDialog(
      title: strings.recordShortcut,
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.pressShortcutDescription),
            const SizedBox(height: 20),
            DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted(context),
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                child: Text(
                  _preview == null ? '…' : formatChord(_preview!),
                  style: AppTextStyles.title(context),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        AppButton(
          label: strings.cancel,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          label: strings.apply,
          kind: AppButtonKind.primary,
          onPressed: _preview == null
              ? null
              : () => Navigator.pop(
                    context,
                    _preview!.copyWith(enabled: widget.initial.enabled),
                  ),
        ),
      ],
    );
  }
}

Future<String?> askForProfileName(
  BuildContext context, {
  required String title,
  required String initialValue,
}) async {
  final strings = AppLocalizations.of(context)!;
  var value = initialValue;
  final result = await showAppDialog<String>(
    context: context,
    barrierLabel: strings.dismiss,
    builder: (dialogContext) => AppDialog(
      title: title,
      content: SizedBox(
        width: 380,
        child: AppTextField(
          initialValue: initialValue,
          autofocus: true,
          maxLength: 64,
          onChanged: (next) => value = next,
          onSubmitted: (submitted) {
            if (submitted.trim().isNotEmpty) {
              Navigator.pop(dialogContext, submitted);
            }
          },
        ),
      ),
      actions: [
        AppButton(
          label: strings.cancel,
          onPressed: () => Navigator.pop(dialogContext),
        ),
        AppButton(
          label: strings.apply,
          kind: AppButtonKind.primary,
          onPressed: () {
            if (value.trim().isNotEmpty) {
              Navigator.pop(dialogContext, value);
            }
          },
        ),
      ],
    ),
  );
  return result;
}

String formatChord(KeyChord chord) {
  if (!chord.enabled) return '—';
  return chord.format(currentShortcutPlatform(), separator: ' + ');
}

String actionLabel(AppLocalizations strings, ShortcutAction action) =>
    switch (action) {
      ShortcutAction.showOverlay => strings.showAssistant,
      ShortcutAction.emojify => strings.emojifySelection,
      ShortcutAction.rewrite => strings.rewriteSelection,
      ShortcutAction.fix => strings.fixSelection,
    };

IconData actionIcon(ShortcutAction action) => switch (action) {
      ShortcutAction.showOverlay => LucideIcons.panelTop,
      ShortcutAction.emojify => LucideIcons.smile,
      ShortcutAction.rewrite => LucideIcons.wandSparkles,
      ShortcutAction.fix => LucideIcons.spellCheck,
    };

String issueLabel(AppLocalizations strings, KeyBindingIssueKind kind) =>
    switch (kind) {
      KeyBindingIssueKind.missingBinding => strings.shortcutMissing,
      KeyBindingIssueKind.missingKey => strings.shortcutKeyRequired,
      KeyBindingIssueKind.missingModifier => strings.shortcutModifierRequired,
      KeyBindingIssueKind.unsupportedKey => strings.shortcutKeyUnsupported,
      KeyBindingIssueKind.duplicate => strings.shortcutDuplicate,
      KeyBindingIssueKind.reserved => strings.shortcutReserved,
      KeyBindingIssueKind.unsupportedPlatform =>
        strings.shortcutUnsupportedPlatform,
    };

String? _physicalKeyName(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >= 0x00070004 && usage <= 0x0007001D) {
    return String.fromCharCode(65 + usage - 0x00070004);
  }
  if (usage >= 0x0007001E && usage <= 0x00070026) {
    return '${1 + usage - 0x0007001E}';
  }
  if (usage == 0x00070027) return '0';
  if (usage >= 0x0007003A && usage <= 0x00070045) {
    return 'F${1 + usage - 0x0007003A}';
  }
  if (key == PhysicalKeyboardKey.space) return 'Space';
  if (key == PhysicalKeyboardKey.enter) return 'Enter';
  if (key == PhysicalKeyboardKey.tab) return 'Tab';
  if (key == PhysicalKeyboardKey.delete) return 'Delete';
  if (key == PhysicalKeyboardKey.arrowUp) return 'ArrowUp';
  if (key == PhysicalKeyboardKey.arrowDown) return 'ArrowDown';
  if (key == PhysicalKeyboardKey.arrowLeft) return 'ArrowLeft';
  if (key == PhysicalKeyboardKey.arrowRight) return 'ArrowRight';
  return null;
}

bool _isModifier(LogicalKeyboardKey key) =>
    _isControl(key) || _isAlt(key) || _isShift(key) || _isMeta(key);

bool _isControl(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.control ||
    key == LogicalKeyboardKey.controlLeft ||
    key == LogicalKeyboardKey.controlRight;

bool _isAlt(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.alt ||
    key == LogicalKeyboardKey.altLeft ||
    key == LogicalKeyboardKey.altRight;

bool _isShift(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.shift ||
    key == LogicalKeyboardKey.shiftLeft ||
    key == LogicalKeyboardKey.shiftRight;

bool _isMeta(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.meta ||
    key == LogicalKeyboardKey.metaLeft ||
    key == LogicalKeyboardKey.metaRight;
