import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_surface.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';

final class ProcessingStatusCard extends StatefulWidget {
  const ProcessingStatusCard({super.key});

  @override
  State<ProcessingStatusCard> createState() => _ProcessingStatusCardState();
}

final class _ProcessingStatusCardState extends State<ProcessingStatusCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.disabled(context)) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context)!.loading;
    return Semantics(
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: AppOverlaySurface(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  final wave = Curves.easeInOut.transform(
                    (_controller.value * 2 - 1).abs(),
                  );
                  return Opacity(
                    opacity: 0.56 + (wave * 0.44),
                    child: Transform.translate(
                      offset: Offset(0, -1.5 * wave),
                      child: child,
                    ),
                  );
                },
                child: const Icon(
                  LucideIcons.sparkles,
                  size: 18,
                  color: AppColors.brand,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: AppTextStyles.label(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
