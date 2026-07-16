import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/text_assistant_overlay.dart';

void main() {
  const surfaceSize = Size(1200, 720);

  testWidgets(
    'Flat UI notices match the light visual contract',
    (tester) async {
      await tester.binding.setSurfaceSize(surfaceSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _goldenApp(
          brightness: Brightness.light,
          highContrast: false,
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byKey(const ValueKey('quiet-glass-golden')),
        matchesGoldenFile('flat_ui_notices_light.png'),
      );
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'Flat UI notices match the dark high-contrast contract',
    (tester) async {
      await tester.binding.setSurfaceSize(surfaceSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _goldenApp(
          brightness: Brightness.dark,
          highContrast: true,
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byKey(const ValueKey('quiet-glass-golden')),
        matchesGoldenFile('flat_ui_notices_dark_high_contrast.png'),
      );
    },
    skip: !Platform.isWindows,
  );
}

Widget _goldenApp({
  required Brightness brightness,
  required bool highContrast,
}) =>
    WidgetsApp(
      color: AppColors.canvasFor(brightness),
      pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, __) => builder(context),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            highContrast: highContrast,
            disableAnimations: true,
          ),
          child: AppThemeScope(
            brightness: brightness,
            child: Builder(
              builder: (context) => DefaultTextStyle(
                style: AppTextStyles.body(context),
                child: ColoredBox(
                  color: AppColors.canvas(context),
                  child: RepaintBoundary(
                    key: const ValueKey('quiet-glass-golden'),
                    child: const Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                _NoticeSample(
                                  icon: LucideIcons.triangleAlert,
                                  title: 'Processing failed',
                                  accentColor: AppColors.danger,
                                  secondaryLabel: 'Dismiss',
                                ),
                                SizedBox(height: AppSpacing.md),
                                _NoticeSample(
                                  icon: LucideIcons.info,
                                  title: 'Completed with a warning',
                                  accentColor: AppColors.warning,
                                  description:
                                      'The result may already be in the target application.',
                                  secondaryLabel: 'Dismiss',
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: AppSpacing.lg),
                          Expanded(
                            child: Column(
                              children: [
                                _NoticeSample(
                                  icon: LucideIcons.clipboardCheck,
                                  title: 'Clipboard recovery needed',
                                  description:
                                      'The original clipboard could not be restored safely. Retry without overwriting newer external data.',
                                  primaryLabel: 'Retry recovery',
                                  secondaryLabel: 'Dismiss',
                                ),
                                SizedBox(height: AppSpacing.md),
                                _NoticeSample(
                                  icon: LucideIcons.clipboardPaste,
                                  title: 'Ready to paste',
                                  description:
                                      'The transformed text is in the clipboard. Return to the target app and paste it manually.',
                                  secondaryLabel: 'Dismiss',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

class _NoticeSample extends StatelessWidget {
  const _NoticeSample({
    required this.icon,
    required this.title,
    this.accentColor,
    this.description,
    this.primaryLabel,
    required this.secondaryLabel,
  });

  final IconData icon;
  final String title;
  final Color? accentColor;
  final String? description;
  final String? primaryLabel;
  final String secondaryLabel;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 300,
        child: Align(
          alignment: Alignment.topCenter,
          child: OverlayNotice(
            icon: icon,
            title: title,
            accentColor: accentColor,
            description: description,
            primaryLabel: primaryLabel,
            onPrimary: primaryLabel == null ? null : _doNothing,
            secondaryLabel: secondaryLabel,
            onSecondary: _doNothing,
          ),
        ),
      );
}

void _doNothing() {}
