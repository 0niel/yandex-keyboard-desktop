import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:yandex_keyboard_desktop/l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/application/privacy_activity_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/presentation/settings_widgets.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';

class PrivacySettingsPage extends StatelessWidget {
  const PrivacySettingsPage({
    super.key,
    required this.settings,
    required this.manualClipboardMode,
  });

  final AppSettings settings;
  final bool manualClipboardMode;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    final settingsController = context.read<SettingsController>();
    final activityController = context.read<PrivacyActivityController>();
    return SettingsPageScroll(
      title: strings.privacySettings,
      description: strings.privacySettingsDescription,
      children: [
        InlineNotice(
          icon: LucideIcons.shield,
          title: strings.localPrivacyGuarantee,
          description: strings.localPrivacyGuaranteeDescription,
        ),
        SettingGroup(
          title: strings.clipboardBehavior,
          children: [
            if (manualClipboardMode)
              Text(
                strings.manualClipboardPolicyDescription,
                style: TextStyle(
                  color: AppColors.textSecondary(context),
                  height: 1.4,
                ),
              )
            else
              SettingRow(
                label: strings.clipboardBehavior,
                control: AppSelect<ClipboardPolicy>(
                  value: settings.clipboardPolicy,
                  items: {
                    ClipboardPolicy.restoreOriginal:
                        strings.restoreOriginalClipboard,
                    ClipboardPolicy.keepReplacement:
                        strings.keepReplacementClipboard,
                  },
                  onChanged: (value) =>
                      settingsController.updateGeneral(clipboardPolicy: value),
                ),
              ),
          ],
        ),
        SettingGroup(
          title: strings.localData,
          children: [
            SettingRow(
              label: strings.saveHistory,
              description: strings.historyMetadataDescription,
              control: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: AppSwitch(
                  label: strings.saveHistory,
                  value: settings.historyEnabled,
                  onChanged: (value) =>
                      settingsController.updateGeneral(historyEnabled: value),
                ),
              ),
            ),
            SettingRow(
              label: strings.diagnostics,
              description: strings.diagnosticsMetadataDescription,
              control: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: AppSwitch(
                  label: strings.diagnostics,
                  value: settings.diagnosticsEnabled,
                  onChanged: (value) => settingsController.updateGeneral(
                    diagnosticsEnabled: value,
                  ),
                ),
              ),
            ),
          ],
        ),
        BlocBuilder<PrivacyActivityController, PrivacyActivityState>(
          builder: (context, state) {
            final busy = state.stage == PrivacyActivityStage.busy;
            final snapshot = state.snapshot;
            return SettingGroup(
              title: strings.recentHistory,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _Metric(
                        label: strings.historyCount(state.historyCount),
                        value: state.historyCount,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _Metric(
                        label: strings.diagnosticsCount(state.diagnosticsCount),
                        value: state.diagnosticsCount,
                      ),
                    ),
                  ],
                ),
                Text(
                  strings.privacyRetentionDescription,
                  style: TextStyle(
                    color: AppColors.textSecondary(context),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                if (snapshot != null && snapshot.history.isNotEmpty)
                  for (final entry in snapshot.history.take(5))
                    _HistoryRow(entry: entry),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AppButton(
                      label: strings.clearHistory,
                      onPressed: busy ||
                              (state.historyCount == 0 &&
                                  state.stage != PrivacyActivityStage.failure)
                          ? null
                          : () => _confirm(
                                context,
                                title: strings.clearHistory,
                                description: strings.clearHistoryConfirmation,
                                action: activityController.clearHistory,
                              ),
                    ),
                    AppButton(
                      label: strings.clearDiagnostics,
                      onPressed: busy ||
                              (state.diagnosticsCount == 0 &&
                                  state.managedExportCount == 0 &&
                                  state.stage != PrivacyActivityStage.failure)
                          ? null
                          : () => _confirm(
                                context,
                                title: strings.clearDiagnostics,
                                description:
                                    strings.clearDiagnosticsConfirmation,
                                action: activityController.clearDiagnostics,
                              ),
                    ),
                    AppButton(
                      label: strings.exportDiagnostics,
                      onPressed: busy || state.diagnosticsCount == 0
                          ? null
                          : activityController.exportDiagnostics,
                      icon: LucideIcons.download,
                      kind: AppButtonKind.primary,
                    ),
                  ],
                ),
                if (state.lastExportPath case final path?) ...[
                  Text(
                    strings.diagnosticsExportedTo,
                    style: TextStyle(color: AppColors.textSecondary(context)),
                  ),
                  AppTextField(initialValue: path, readOnly: true),
                ],
                if (state.errorCode != null)
                  Text(
                    strings.privacyDataOperationFailed,
                    style: const TextStyle(color: AppColors.danger),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted(context),
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$value',
                style: AppTextStyles.display(context),
              ),
              Text(
                label,
                maxLines: 2,
                style: TextStyle(
                  color: AppColors.textSecondary(context),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      );
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry});

  final PrivacyHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context)!;
    return Row(
      children: [
        Icon(_historyIcon(entry.outcome), size: 16, color: AppColors.brand),
        const SizedBox(width: 8),
        Expanded(child: Text(_actionLabel(strings, entry.action))),
        Text(
          _outcomeLabel(strings, entry.outcome),
          style: TextStyle(
            color: AppColors.textSecondary(context),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

Future<void> _confirm(
  BuildContext context, {
  required String title,
  required String description,
  required Future<void> Function() action,
}) async {
  final strings = AppLocalizations.of(context)!;
  final confirmed = await showAppDialog<bool>(
    context: context,
    barrierLabel: strings.dismiss,
    builder: (context) => AppDialog(
      title: title,
      content: Text(description),
      actions: [
        AppButton(
          label: strings.cancel,
          onPressed: () => Navigator.pop(context, false),
        ),
        AppButton(
          label: strings.clear,
          kind: AppButtonKind.danger,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    ),
  );
  if (confirmed == true) await action();
}

IconData _historyIcon(PrivacyActivityOutcome outcome) => switch (outcome) {
      PrivacyActivityOutcome.completed => LucideIcons.circleCheck,
      PrivacyActivityOutcome.completedWithWarning => LucideIcons.info,
      PrivacyActivityOutcome.cancelled => LucideIcons.circleMinus,
      PrivacyActivityOutcome.failed => LucideIcons.triangleAlert,
    };

String _actionLabel(AppLocalizations strings, TextAction action) =>
    switch (action) {
      TextAction.emojify => strings.emojify,
      TextAction.rewrite => strings.improve,
      TextAction.fix => strings.fix,
    };

String _outcomeLabel(
  AppLocalizations strings,
  PrivacyActivityOutcome outcome,
) =>
    switch (outcome) {
      PrivacyActivityOutcome.completed => strings.historyCompleted,
      PrivacyActivityOutcome.completedWithWarning => strings.historyWarning,
      PrivacyActivityOutcome.cancelled => strings.historyCancelled,
      PrivacyActivityOutcome.failed => strings.historyFailed,
    };
