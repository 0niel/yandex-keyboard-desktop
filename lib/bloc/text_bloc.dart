import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'text_event.dart';
import 'text_state.dart';
import 'text_processing_type.dart';

class TextBloc extends Bloc<TextEvent, TextState> {
  TextBloc() : super(TextInitial()) {
    on<ProcessTextEvent>(_onProcessTextEvent);
    on<ClearTextEvent>((event, emit) => emit(TextInitial()));
  }

  Future<void> _onProcessTextEvent(ProcessTextEvent event, Emitter<TextState> emit) async {
    emit(TextProcessing());
    try {
      final url = _getUrl(event.type);
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'User-Agent': 'okhttp/4.12.0',
          'Connection': 'Keep-Alive',
          'Accept-Encoding': 'gzip',
        },
        body: jsonEncode({'text': event.text}),
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        emit(TextProcessed(responseData['response']));
      } else {
        emit(const TextError('Failed to process text'));
      }
    } catch (e) {
      emit(TextError('Failed to process text: $e'));
    }
  }

  String _getUrl(TextProcessingType type) {
    switch (type) {
      case TextProcessingType.emojify:
        return 'https://keyboard.yandex.net/gpt/emoji';
      case TextProcessingType.rewrite:
        return 'https://keyboard.yandex.net/gpt/rewrite';
      case TextProcessingType.fix:
        return 'https://keyboard.yandex.net/gpt/fix';
      default:
        throw ArgumentError('Unknown TextProcessingType: $type');
    }
  }
}
