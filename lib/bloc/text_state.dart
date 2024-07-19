import 'package:equatable/equatable.dart';

abstract class TextState extends Equatable {
  const TextState();
}

class TextInitial extends TextState {
  @override
  List<Object> get props => [];
}

class TextProcessing extends TextState {
  @override
  List<Object> get props => [];
}

class TextProcessed extends TextState {
  final String processedText;

  const TextProcessed(this.processedText);

  @override
  List<Object> get props => [processedText];
}

class TextError extends TextState {
  final String error;

  const TextError(this.error);

  @override
  List<Object> get props => [error];
}
