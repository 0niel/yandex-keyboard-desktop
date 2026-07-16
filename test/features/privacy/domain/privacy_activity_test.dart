import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';

void main() {
  test('activity metadata is coarse, allowlisted, and round-trippable', () {
    final event = PrivacyActivityEvent(
      occurredAt: DateTime.utc(2026, 7, 13, 12, 34, 56, 789),
      action: TextAction.fix,
      outcome: PrivacyActivityOutcome.failed,
      durationBucket: privacyDurationBucket(
        const Duration(seconds: 7),
      ),
      platformFamily: PrivacyPlatformFamily.windows,
      failureCode: 'raw secret: swordfish',
      clipboardRestoreSkipped: true,
      clipboardRestoreFailureCode: 'clipboard_restore_failed',
    );

    final encoded = event.toJson();
    final decoded = PrivacyActivityEvent.fromJson(encoded);

    expect(event.occurredAt, DateTime.utc(2026, 7, 13, 12, 34));
    expect(event.durationBucket, PrivacyDurationBucket.underFifteenSeconds);
    expect(event.failureCode, 'unexpected');
    expect(decoded, event);
    expect(jsonEncode(encoded), isNot(contains('swordfish')));
  });

  test('duration bucketing does not retain exact timings', () {
    expect(
      privacyDurationBucket(const Duration(milliseconds: -1)),
      PrivacyDurationBucket.underOneSecond,
    );
    expect(
      privacyDurationBucket(const Duration(milliseconds: 999)),
      PrivacyDurationBucket.underOneSecond,
    );
    expect(
      privacyDurationBucket(const Duration(seconds: 1)),
      PrivacyDurationBucket.underFiveSeconds,
    );
    expect(
      privacyDurationBucket(const Duration(seconds: 5)),
      PrivacyDurationBucket.underFifteenSeconds,
    );
    expect(
      privacyDurationBucket(const Duration(seconds: 15)),
      PrivacyDurationBucket.underOneMinute,
    );
    expect(
      privacyDurationBucket(const Duration(minutes: 1)),
      PrivacyDurationBucket.oneMinuteOrMore,
    );
  });

  test('history serialization contains only its closed metadata fields', () {
    final entry = PrivacyHistoryEntry(
      occurredAt: DateTime.utc(2026, 7, 13, 12, 34, 56),
      action: TextAction.emojify,
      outcome: PrivacyActivityOutcome.completed,
    );
    final json = entry.toJson();

    expect(json.keys, {'occurredAt', 'action', 'outcome'});
    expect(PrivacyHistoryEntry.fromJson(json), entry);
  });

  test('all persisted platform families use closed enum values', () {
    for (final platform in PrivacyPlatformFamily.values) {
      final event = PrivacyActivityEvent(
        occurredAt: DateTime.utc(2026, 7, 13, 12),
        action: TextAction.rewrite,
        outcome: PrivacyActivityOutcome.cancelled,
        durationBucket: PrivacyDurationBucket.oneMinuteOrMore,
        platformFamily: platform,
        clipboardRestoreSkipped: false,
      );
      expect(PrivacyActivityEvent.fromJson(event.toJson()), event);
    }
  });

  test('no-op recorder accepts metadata without side effects', () async {
    await const NoOpPrivacyActivityRecorder().record(
      PrivacyActivityEvent(
        occurredAt: DateTime.utc(2026, 7, 13, 12),
        action: TextAction.rewrite,
        outcome: PrivacyActivityOutcome.completed,
        durationBucket: PrivacyDurationBucket.underOneSecond,
        platformFamily: PrivacyPlatformFamily.unknown,
        clipboardRestoreSkipped: false,
      ),
      consent: const PrivacyConsent(
        historyEnabled: true,
        diagnosticsEnabled: true,
        generation: 1,
      ),
    );
  });

  test('invalid persisted enum values fail closed', () {
    expect(
      () => PrivacyHistoryEntry.fromJson({
        'occurredAt': '2026-07-13T12:00:00Z',
        'action': 'copy_private_text',
        'outcome': 'completed',
      }),
      throwsFormatException,
    );
    expect(
      () => PrivacyActivityEvent.fromJson({
        'occurredAt': '2026-07-13T12:00:00Z',
        'action': 'fix',
        'outcome': 'completed',
        'durationBucket': '7.123 seconds',
        'platformFamily': 'windows',
        'clipboardRestoreSkipped': false,
      }),
      throwsFormatException,
    );
  });
}
