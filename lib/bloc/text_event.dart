import 'package:equatable/equatable.dart';

import 'text_processing_type.dart';

abstract class TextEvent extends Equatable {
  const TextEvent();

  @override
  List<Object> get props => [];
}

class ProcessTextEvent extends TextEvent {
  final String text;
  final TextProcessingType type;

  const ProcessTextEvent(this.text, this.type);

  @override
  List<Object> get props => [text, type];
}

class ClearTextEvent extends TextEvent {}
