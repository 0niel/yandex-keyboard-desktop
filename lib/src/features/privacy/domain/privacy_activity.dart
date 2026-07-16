import 'package:equatable/equatable.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';

enum PrivacyActivityOutcome {
  completed,
  completedWithWarning,
  cancelled,
  failed,
}

enum PrivacyDurationBucket {
  underOneSecond,
  underFiveSeconds,
  underFifteenSeconds,
  underOneMinute,
  oneMinuteOrMore,
}

enum PrivacyPlatformFamily { windows, linux, ios, macos, unknown }

final class PrivacyActivityEvent extends Equatable {
  PrivacyActivityEvent({
    required DateTime occurredAt,
    required this.action,
    required this.outcome,
    required this.durationBucket,
    required this.platformFamily,
    String? failureCode,
    required this.clipboardRestoreSkipped,
    String? clipboardRestoreFailureCode,
  })  : occurredAt = _roundToMinute(occurredAt),
        failureCode = sanitizeDiagnosticCode(failureCode),
        clipboardRestoreFailureCode =
            sanitizeDiagnosticCode(clipboardRestoreFailureCode);

  final DateTime occurredAt;
  final TextAction action;
  final PrivacyActivityOutcome outcome;
  final PrivacyDurationBucket durationBucket;
  final PrivacyPlatformFamily platformFamily;
  final String? failureCode;
  final bool clipboardRestoreSkipped;
  final String? clipboardRestoreFailureCode;

  PrivacyHistoryEntry toHistoryEntry() => PrivacyHistoryEntry(
        occurredAt: occurredAt,
        action: action,
        outcome: outcome,
      );

  Map<String, Object?> toJson() => {
        'occurredAt': occurredAt.toIso8601String(),
        'action': action.name,
        'outcome': outcome.name,
        'durationBucket': durationBucket.name,
        'platformFamily': platformFamily.name,
        if (failureCode != null) 'failureCode': failureCode,
        'clipboardRestoreSkipped': clipboardRestoreSkipped,
        if (clipboardRestoreFailureCode != null)
          'clipboardRestoreFailureCode': clipboardRestoreFailureCode,
      };

  factory PrivacyActivityEvent.fromJson(Map<String, dynamic> json) {
    final rawOccurredAt = json['occurredAt'];
    final occurredAt =
        rawOccurredAt is String ? DateTime.tryParse(rawOccurredAt) : null;
    final skipped = json['clipboardRestoreSkipped'];
    if (occurredAt == null || skipped is! bool) {
      throw const FormatException('Invalid diagnostic activity record.');
    }
    return PrivacyActivityEvent(
      occurredAt: occurredAt,
      action: _parseAction(json['action']),
      outcome: _parseOutcome(json['outcome']),
      durationBucket: _parseDurationBucket(json['durationBucket']),
      platformFamily: _parsePlatformFamily(json['platformFamily']),
      failureCode:
          json['failureCode'] is String ? json['failureCode'] as String : null,
      clipboardRestoreSkipped: skipped,
      clipboardRestoreFailureCode: json['clipboardRestoreFailureCode'] is String
          ? json['clipboardRestoreFailureCode'] as String
          : null,
    );
  }

  @override
  List<Object?> get props => [
        occurredAt,
        action,
        outcome,
        durationBucket,
        platformFamily,
        failureCode,
        clipboardRestoreSkipped,
        clipboardRestoreFailureCode,
      ];
}

final class PrivacyHistoryEntry extends Equatable {
  PrivacyHistoryEntry({
    required DateTime occurredAt,
    required this.action,
    required this.outcome,
  }) : occurredAt = _roundToMinute(occurredAt);

  final DateTime occurredAt;
  final TextAction action;
  final PrivacyActivityOutcome outcome;

  Map<String, Object> toJson() => {
        'occurredAt': occurredAt.toIso8601String(),
        'action': action.name,
        'outcome': outcome.name,
      };

  factory PrivacyHistoryEntry.fromJson(Map<String, dynamic> json) {
    final rawOccurredAt = json['occurredAt'];
    final occurredAt =
        rawOccurredAt is String ? DateTime.tryParse(rawOccurredAt) : null;
    if (occurredAt == null) {
      throw const FormatException('Invalid history activity record.');
    }
    return PrivacyHistoryEntry(
      occurredAt: occurredAt,
      action: _parseAction(json['action']),
      outcome: _parseOutcome(json['outcome']),
    );
  }

  @override
  List<Object?> get props => [occurredAt, action, outcome];
}

final class PrivacyActivitySnapshot extends Equatable {
  PrivacyActivitySnapshot({
    required List<PrivacyHistoryEntry> history,
    required List<PrivacyActivityEvent> diagnostics,
    List<String> managedExportPaths = const [],
    this.managedExportsKnown = true,
  })  : history = List.unmodifiable(history),
        diagnostics = List.unmodifiable(diagnostics),
        managedExportPaths = List.unmodifiable(managedExportPaths);

  factory PrivacyActivitySnapshot.empty() => PrivacyActivitySnapshot(
        history: const [],
        diagnostics: const [],
      );

  final List<PrivacyHistoryEntry> history;
  final List<PrivacyActivityEvent> diagnostics;
  final List<String> managedExportPaths;
  final bool managedExportsKnown;

  int get managedExportCount => managedExportPaths.length;

  @override
  List<Object?> get props => [
        history,
        diagnostics,
        managedExportPaths,
        managedExportsKnown,
      ];
}

final class PrivacyConsent extends Equatable {
  const PrivacyConsent({
    required this.historyEnabled,
    required this.diagnosticsEnabled,
    required this.generation,
  });

  const PrivacyConsent.disabled()
      : historyEnabled = false,
        diagnosticsEnabled = false,
        generation = 0;

  final bool historyEnabled;
  final bool diagnosticsEnabled;
  final int generation;

  bool get anyEnabled => historyEnabled || diagnosticsEnabled;

  @override
  List<Object?> get props => [historyEnabled, diagnosticsEnabled, generation];
}

abstract interface class PrivacyConsentProvider {
  PrivacyConsent get currentPrivacyConsent;
}

abstract interface class PrivacyActivityRecorder {
  Future<void> record(
    PrivacyActivityEvent event, {
    required PrivacyConsent consent,
  });
}

final class NoOpPrivacyActivityRecorder implements PrivacyActivityRecorder {
  const NoOpPrivacyActivityRecorder();

  @override
  Future<void> record(
    PrivacyActivityEvent event, {
    required PrivacyConsent consent,
  }) async {}
}

abstract interface class PrivacyActivityRepository {
  Future<PrivacyActivitySnapshot> load();

  Future<PrivacyActivitySnapshot> record(
    PrivacyActivityEvent event, {
    required PrivacyConsent consent,
  });

  Future<PrivacyActivitySnapshot> clearHistory();

  Future<PrivacyActivitySnapshot> clearDiagnostics();

  Future<String> exportDiagnostics();
}

String? sanitizeDiagnosticCode(String? value) {
  if (value == null) return null;
  return _allowedDiagnosticCodes.contains(value) ? value : 'unexpected';
}

PrivacyDurationBucket privacyDurationBucket(Duration duration) {
  if (duration.isNegative) return PrivacyDurationBucket.underOneSecond;
  if (duration < const Duration(seconds: 1)) {
    return PrivacyDurationBucket.underOneSecond;
  }
  if (duration < const Duration(seconds: 5)) {
    return PrivacyDurationBucket.underFiveSeconds;
  }
  if (duration < const Duration(seconds: 15)) {
    return PrivacyDurationBucket.underFifteenSeconds;
  }
  if (duration < const Duration(minutes: 1)) {
    return PrivacyDurationBucket.underOneMinute;
  }
  return PrivacyDurationBucket.oneMinuteOrMore;
}

TextAction _parseAction(Object? value) => switch (value) {
      'emojify' => TextAction.emojify,
      'rewrite' => TextAction.rewrite,
      'fix' => TextAction.fix,
      _ => throw const FormatException('Invalid activity action.'),
    };

PrivacyActivityOutcome _parseOutcome(Object? value) => switch (value) {
      'completed' => PrivacyActivityOutcome.completed,
      'completedWithWarning' => PrivacyActivityOutcome.completedWithWarning,
      'cancelled' => PrivacyActivityOutcome.cancelled,
      'failed' => PrivacyActivityOutcome.failed,
      _ => throw const FormatException('Invalid activity outcome.'),
    };

PrivacyDurationBucket _parseDurationBucket(Object? value) => switch (value) {
      'underOneSecond' => PrivacyDurationBucket.underOneSecond,
      'underFiveSeconds' => PrivacyDurationBucket.underFiveSeconds,
      'underFifteenSeconds' => PrivacyDurationBucket.underFifteenSeconds,
      'underOneMinute' => PrivacyDurationBucket.underOneMinute,
      'oneMinuteOrMore' => PrivacyDurationBucket.oneMinuteOrMore,
      _ => throw const FormatException('Invalid duration bucket.'),
    };

PrivacyPlatformFamily _parsePlatformFamily(Object? value) => switch (value) {
      'windows' => PrivacyPlatformFamily.windows,
      'linux' => PrivacyPlatformFamily.linux,
      'ios' => PrivacyPlatformFamily.ios,
      'macos' => PrivacyPlatformFamily.macos,
      'unknown' => PrivacyPlatformFamily.unknown,
      _ => throw const FormatException('Invalid platform family.'),
    };

DateTime _roundToMinute(DateTime value) {
  final utc = value.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day, utc.hour, utc.minute);
}

const _allowedDiagnosticCodes = {
  'clipboard_lossless_snapshot_unavailable',
  'clipboard_restore_failed',
  'clipboard_snapshot_format_unsupported',
  'clipboard_snapshot_unstable',
  'selection_commit_completed_after_cancel',
  'selection_commit_unverified',
  'selection_copy_stale',
  'selection_focus_not_restored',
  'selection_injection_rejected',
  'selection_lease_missing',
  'selection_stage_failed',
  'selection_stage_lease_lost',
  'selection_stage_revision_unchanged',
  'selection_target_changed',
  'selection_target_changed_before_commit',
  'selection_target_changed_during_copy',
  'selection_target_unavailable',
  'text_replacement_failed',
  'text_replacement_unexpected',
  'transform_http_rejected',
  'transform_invalid_response',
  'transform_network_error',
  'transform_timeout',
};
