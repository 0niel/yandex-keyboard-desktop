import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_surface.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';

final class ReplacementSuccessCard extends StatelessWidget {
  const ReplacementSuccessCard({super.key});

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context)!.replacementDone;
    return Semantics(
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: AppOverlaySurface(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                LucideIcons.check,
                size: 18,
                color: AppColors.success,
              ),
              const SizedBox(width: 8),
              Text(label, style: AppTextStyles.label(context)),
            ],
          ),
        ),
      ),
    );
  }
}
