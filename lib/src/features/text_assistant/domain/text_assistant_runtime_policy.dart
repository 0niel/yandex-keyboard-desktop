import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';

final class TextAssistantRuntimePolicy {
  const TextAssistantRuntimePolicy({
    required this.requestTimeout,
    required this.retryAttempts,
    required this.restoreOriginalClipboard,
    required this.defaultAction,
    this.historyEnabled = false,
    this.diagnosticsEnabled = false,
    this.privacyConsentGeneration = 0,
  }) : assert(retryAttempts >= 0 && retryAttempts <= 8);

  const TextAssistantRuntimePolicy.defaults()
      : requestTimeout = const Duration(seconds: 15),
        retryAttempts = 2,
        restoreOriginalClipboard = true,
        defaultAction = TextAction.rewrite,
        historyEnabled = false,
        diagnosticsEnabled = false,
        privacyConsentGeneration = 0;

  final Duration requestTimeout;
  final int retryAttempts;
  final bool restoreOriginalClipboard;
  final TextAction defaultAction;
  final bool historyEnabled;
  final bool diagnosticsEnabled;
  final int privacyConsentGeneration;
}

abstract interface class TextAssistantRuntimePolicyProvider {
  TextAssistantRuntimePolicy get current;
}

final class FixedTextAssistantRuntimePolicyProvider
    implements TextAssistantRuntimePolicyProvider, PrivacyConsentProvider {
  const FixedTextAssistantRuntimePolicyProvider([
    this.current = const TextAssistantRuntimePolicy.defaults(),
  ]);

  @override
  final TextAssistantRuntimePolicy current;

  @override
  PrivacyConsent get currentPrivacyConsent => PrivacyConsent(
        historyEnabled: current.historyEnabled,
        diagnosticsEnabled: current.diagnosticsEnabled,
        generation: current.privacyConsentGeneration,
      );
}

final class MutableTextAssistantRuntimePolicyProvider
    implements TextAssistantRuntimePolicyProvider, PrivacyConsentProvider {
  MutableTextAssistantRuntimePolicyProvider({
    TextAssistantRuntimePolicy initial =
        const TextAssistantRuntimePolicy.defaults(),
  }) : _current = initial;

  TextAssistantRuntimePolicy _current;

  @override
  TextAssistantRuntimePolicy get current => _current;

  @override
  PrivacyConsent get currentPrivacyConsent => PrivacyConsent(
        historyEnabled: current.historyEnabled,
        diagnosticsEnabled: current.diagnosticsEnabled,
        generation: current.privacyConsentGeneration,
      );

  void replace(TextAssistantRuntimePolicy policy) {
    _current = policy;
  }
}
