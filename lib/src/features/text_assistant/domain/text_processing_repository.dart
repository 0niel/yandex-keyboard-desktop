import 'dart:async';

import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'text_assistant_runtime_policy.dart';

abstract interface class TextProcessingRepository {
  Future<String> process({
    required String text,
    required TextAction action,
    TextAssistantRuntimePolicy? policy,
    TextProcessingCancellationToken? cancellationToken,
  });
}

final class TextProcessingCancellationToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

enum TextProcessingFailureKind {
  cancelled,
  timeout,
  network,
  rejected,
  invalidResponse,
  inputTooLarge,
  responseTooLarge,
}

final class TextProcessingException implements Exception {
  const TextProcessingException({
    required this.kind,
    required this.diagnosticCode,
    this.statusCode,
  });

  final TextProcessingFailureKind kind;
  final String diagnosticCode;
  final int? statusCode;

  @override
  String toString() => 'TextProcessingException($diagnosticCode)';
}
