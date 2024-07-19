import 'package:fluent_ui/fluent_ui.dart' as fluent;
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
    final simpleCommandBarItems = <fluent.CommandBarItem>[
      fluent.CommandBarButton(
        icon: const Icon(fluent.FluentIcons.emoji),
        label: const Text('Emojify'),
        onPressed: () {
          logger.i("Emojify button pressed");
          processClipboardText(context, 'emojify');
        },
      ),
      fluent.CommandBarButton(
        icon: const Icon(fluent.FluentIcons.edit),
        label: const Text('Улучшить'),
        onPressed: () {
          logger.i("Rewrite button pressed");
          processClipboardText(context, 'rewrite');
        },
      ),
    ];

    return fluent.CommandBarCard(
      backgroundColor: fluent.Colors.white,
      child: fluent.CommandBar(
        primaryItems: [
          ...simpleCommandBarItems,
        ],
      ),
    );
  }
}
