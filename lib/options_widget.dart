import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

class OptionsWidget extends StatelessWidget {
  final Logger logger;
  final Future<void> Function(BuildContext context, String type) processClipboardText;

  const OptionsWidget({
    super.key,
    required this.logger,
    required this.processClipboardText,
  });

  @override
  Widget build(BuildContext context) {
    final style = ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF111827),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4.0),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      textStyle: const TextStyle(
        fontSize: 14.0,
        fontWeight: FontWeight.w500,
        color: Colors.white,
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: ElevatedButton.icon(
                style: style,
                onPressed: () {
                  logger.i("Emojify button pressed");
                  processClipboardText(context, 'emojify');
                },
                icon: const Icon(Icons.emoji_emotions),
                label: const Text('Emojify', textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 4.0),
            Expanded(
              child: ElevatedButton.icon(
                style: style,
                onPressed: () {
                  logger.i("Rewrite button pressed");
                  processClipboardText(context, 'rewrite');
                },
                icon: const Icon(Icons.edit),
                label: const Text('Улучшить', textAlign: TextAlign.center),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
