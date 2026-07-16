import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_surface.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';

class StartupHotKeyErrorBanner extends StatelessWidget {
  const StartupHotKeyErrorBanner({
    super.key,
    required this.rollbackFailed,
    required this.onClose,
    this.conflictedChords,
  });

  final bool rollbackFailed;
  final VoidCallback onClose;

  final String? conflictedChords;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    final chords = conflictedChords;
    final description = chords != null && chords.isNotEmpty
        ? strings.hotkeyConflictDescription(chords)
        : rollbackFailed
            ? strings.hotkeyRollbackFailed
            : strings.hotkeyRegistrationFailed;
    return Semantics(
      container: true,
      liveRegion: true,
      label: '${strings.hotkeyErrorTitle}. $description',
      child: AppOverlaySurface(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              LucideIcons.triangleAlert,
              size: 20,
              color: AppColors.danger,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.hotkeyErrorTitle,
                    style: AppTextStyles.title(context),
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    description,
                    style: TextStyle(color: AppColors.textSecondary(context)),
                  ),
                ],
              ),
            ),
            AppIconButton(
              label: strings.dismiss,
              icon: LucideIcons.x,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
