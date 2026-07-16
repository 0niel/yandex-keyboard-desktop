import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';

final class TextAssistantSettingsApplier
    implements SettingsRuntimeApplier, SettingsDraftPrivacyApplier {
  const TextAssistantSettingsApplier({required this.policyProvider});

  final MutableTextAssistantRuntimePolicyProvider policyProvider;

  @override
  Future<void> apply({
    required AppSettings previous,
    required AppSettings next,
  }) async {
    final current = policyProvider.current;
    final consentChanged = current.historyEnabled != next.historyEnabled ||
        current.diagnosticsEnabled != next.diagnosticsEnabled;
    policyProvider.replace(TextAssistantRuntimePolicy(
      requestTimeout: Duration(
        milliseconds: next.requestTimeoutMilliseconds,
      ),
      retryAttempts: next.retryAttempts,
      restoreOriginalClipboard:
          next.clipboardPolicy == ClipboardPolicy.restoreOriginal,
      defaultAction: _textActionFor(next.defaultAction),
      historyEnabled: next.historyEnabled,
      diagnosticsEnabled: next.diagnosticsEnabled,
      privacyConsentGeneration: consentChanged
          ? current.privacyConsentGeneration + 1
          : current.privacyConsentGeneration,
    ));
  }

  @override
  void applyWithdrawal({
    required AppSettings previousDraft,
    required AppSettings nextDraft,
  }) {
    final current = policyProvider.current;
    _replaceConsent(
      historyEnabled: current.historyEnabled && nextDraft.historyEnabled,
      diagnosticsEnabled:
          current.diagnosticsEnabled && nextDraft.diagnosticsEnabled,
    );
  }

  @override
  void discard({required AppSettings authoritative}) {
    _replaceConsent(
      historyEnabled: authoritative.historyEnabled,
      diagnosticsEnabled: authoritative.diagnosticsEnabled,
    );
  }

  void _replaceConsent({
    required bool historyEnabled,
    required bool diagnosticsEnabled,
  }) {
    final current = policyProvider.current;
    final changed = current.historyEnabled != historyEnabled ||
        current.diagnosticsEnabled != diagnosticsEnabled;
    if (!changed) return;
    policyProvider.replace(TextAssistantRuntimePolicy(
      requestTimeout: current.requestTimeout,
      retryAttempts: current.retryAttempts,
      restoreOriginalClipboard: current.restoreOriginalClipboard,
      defaultAction: current.defaultAction,
      historyEnabled: historyEnabled,
      diagnosticsEnabled: diagnosticsEnabled,
      privacyConsentGeneration: current.privacyConsentGeneration + 1,
    ));
  }

  TextAction _textActionFor(ShortcutAction action) => switch (action) {
        ShortcutAction.emojify => TextAction.emojify,
        ShortcutAction.rewrite => TextAction.rewrite,
        ShortcutAction.fix => TextAction.fix,
        ShortcutAction.showOverlay => throw StateError(
            'showOverlay cannot be used as a text default action.',
          ),
      };
}
