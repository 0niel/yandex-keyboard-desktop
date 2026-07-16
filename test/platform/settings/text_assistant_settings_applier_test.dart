import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/platform/settings/text_assistant_settings_applier.dart';

void main() {
  test('maps persisted settings to the shared live text policy', () async {
    final provider = MutableTextAssistantRuntimePolicyProvider();
    final applier = TextAssistantSettingsApplier(policyProvider: provider);
    final next = AppSettings.defaults().copyWith(
      defaultAction: ShortcutAction.fix,
      clipboardPolicy: ClipboardPolicy.keepReplacement,
      requestTimeoutMilliseconds: 30000,
      retryAttempts: 4,
      historyEnabled: true,
      diagnosticsEnabled: true,
    );

    await applier.apply(previous: AppSettings.defaults(), next: next);

    expect(provider.current.defaultAction, TextAction.fix);
    expect(provider.current.restoreOriginalClipboard, isFalse);
    expect(provider.current.requestTimeout, const Duration(seconds: 30));
    expect(provider.current.retryAttempts, 4);
    expect(provider.current.historyEnabled, isTrue);
    expect(provider.current.diagnosticsEnabled, isTrue);
    expect(provider.current.privacyConsentGeneration, 1);
  });

  test('reapplying the authoritative snapshot rolls live policy back',
      () async {
    final provider = MutableTextAssistantRuntimePolicyProvider();
    final applier = TextAssistantSettingsApplier(policyProvider: provider);
    final original = AppSettings.defaults();
    final attempted = original.copyWith(
      clipboardPolicy: ClipboardPolicy.keepReplacement,
      retryAttempts: 5,
    );

    await applier.apply(previous: original, next: attempted);
    await applier.apply(previous: attempted, next: original);

    expect(provider.current.restoreOriginalClipboard, isTrue);
    expect(provider.current.retryAttempts, original.retryAttempts);
    expect(provider.current.defaultAction, TextAction.rewrite);
  });

  test('privacy consent generation changes only when consent changes',
      () async {
    final provider = MutableTextAssistantRuntimePolicyProvider();
    final applier = TextAssistantSettingsApplier(policyProvider: provider);
    final defaults = AppSettings.defaults();

    await applier.apply(
      previous: defaults,
      next: defaults.copyWith(retryAttempts: 4),
    );
    expect(provider.current.privacyConsentGeneration, 0);

    await applier.apply(
      previous: defaults,
      next: defaults.copyWith(historyEnabled: true),
    );
    expect(provider.current.privacyConsentGeneration, 1);

    await applier.apply(
      previous: defaults.copyWith(historyEnabled: true),
      next: defaults,
    );
    expect(provider.current.privacyConsentGeneration, 2);
  });
}
