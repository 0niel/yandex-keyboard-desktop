import 'package:equatable/equatable.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';

enum TextReplacementStage {
  idle,
  capturing,
  copying,
  processing,
  validatingTarget,
  replacing,
  restoringClipboard,
  completed,
  awaitingManualPaste,
  completedWithWarning,
  cancelled,
  failed,
}

enum TextReplacementOutcome {
  completed,
  completedWithWarning,
  busy,
  cancelled,
  failed,
}

final class TextReplacementState extends Equatable {
  const TextReplacementState({
    this.stage = TextReplacementStage.idle,
    this.action,
    this.failureCode,
    this.clipboardRestoreSkipped = false,
    this.clipboardRestoreFailureCode,
  });

  final TextReplacementStage stage;
  final TextAction? action;
  final String? failureCode;
  final bool clipboardRestoreSkipped;
  final String? clipboardRestoreFailureCode;

  bool get isBusy => switch (stage) {
        TextReplacementStage.capturing ||
        TextReplacementStage.copying ||
        TextReplacementStage.processing ||
        TextReplacementStage.validatingTarget ||
        TextReplacementStage.replacing ||
        TextReplacementStage.restoringClipboard =>
          true,
        _ => false,
      };

  @override
  List<Object?> get props => [
        stage,
        action,
        failureCode,
        clipboardRestoreSkipped,
        clipboardRestoreFailureCode,
      ];
}
