import 'package:equatable/equatable.dart';

abstract class TextEvent extends Equatable {
  const TextEvent();
}

class ProcessTextEvent extends TextEvent {
  final String text;
  final String type;

  const ProcessTextEvent(this.text, this.type);

  @override
  List<Object> get props => [text, type];
}
