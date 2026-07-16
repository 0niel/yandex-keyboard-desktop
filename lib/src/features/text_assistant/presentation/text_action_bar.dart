import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_surface.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/shortcut_platform_context.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';

class TextActionBar extends StatelessWidget {
  const TextActionBar({
    super.key,
    required this.processClipboardText,
    this.manualClipboardMode = false,
    this.onOpenSettings,
  });

  final Future<void> Function(BuildContext context, TextAction action)
      processClipboardText;
  final bool manualClipboardMode;
  final Future<void> Function()? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsController>().state.authoritative;
    final defaultAction = switch (settings?.defaultAction) {
      ShortcutAction.emojify => TextAction.emojify,
      ShortcutAction.fix => TextAction.fix,
      _ => TextAction.rewrite,
    };
    final ordered = [
      defaultAction,
      for (final action in TextAction.values)
        if (action != defaultAction) action,
    ];

    return AppOverlaySurface(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xxs,
        manualClipboardMode ? AppSpacing.xs : AppSpacing.xxs,
        AppSpacing.xxs,
        AppSpacing.xxs,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (manualClipboardMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  strings.manualClipboardInstruction,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textSecondary(context),
                    fontSize: 11,
                    height: 1.25,
                  ),
                ),
              ),
            ),
          Row(
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 5),
                child: BrandMark(size: 22),
              ),
              if (manualClipboardMode && onOpenSettings != null)
                AppIconButton(
                  label: strings.settingsTitle,
                  icon: LucideIcons.slidersHorizontal,
                  onPressed: onOpenSettings,
                ),
              const SizedBox(width: 4),
              for (final action in ordered)
                Expanded(
                  child: _ActionButton(
                    action: action,
                    emphasized: action == defaultAction,
                    chord:
                        settings?.activeProfile.bindings[_shortcutFor(action)],
                    onPressed: () => processClipboardText(context, action),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.action,
    required this.emphasized,
    required this.chord,
    required this.onPressed,
  });

  final TextAction action;
  final bool emphasized;
  final KeyChord? chord;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    final label = _label(strings, action);
    final shortcut = chord?.enabled ?? false ? _formatChord(chord!) : null;
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Semantics(
        hint: shortcut,
        child: AppButton(
          label: label,
          icon: _icon(action),
          kind: emphasized ? AppButtonKind.primary : AppButtonKind.quiet,
          compact: true,
          onPressed: onPressed,
        ),
      ),
    );
  }
}

ShortcutAction _shortcutFor(TextAction action) => switch (action) {
      TextAction.emojify => ShortcutAction.emojify,
      TextAction.rewrite => ShortcutAction.rewrite,
      TextAction.fix => ShortcutAction.fix,
    };

String _label(AppLocalizations strings, TextAction action) => switch (action) {
      TextAction.emojify => strings.emojify,
      TextAction.rewrite => strings.improve,
      TextAction.fix => strings.fix,
    };

IconData _icon(TextAction action) => switch (action) {
      TextAction.emojify => LucideIcons.smile,
      TextAction.rewrite => LucideIcons.wandSparkles,
      TextAction.fix => LucideIcons.spellCheck,
    };

String _formatChord(KeyChord chord) =>
    chord.format(currentShortcutPlatform(), upcaseSingleChar: true);
