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
    final brightness = fluent.FluentTheme.of(context).brightness;
    final backgroundColor = brightness == Brightness.dark ? fluent.Colors.grey[170] : fluent.Colors.white;
    final textColor = brightness == Brightness.dark ? fluent.Colors.white : fluent.Colors.grey[170];

    final simpleCommandBarItems = <fluent.CommandBarItem>[
      fluent.CommandBarButton(
        icon: Icon(fluent.FluentIcons.emoji, color: textColor),
        label: Text('Emojify', style: TextStyle(color: textColor)),
        onPressed: () {
          logger.i("Emojify button pressed");
          processClipboardText(context, 'emojify');
        },
      ),
      fluent.CommandBarButton(
        icon: Icon(fluent.FluentIcons.edit, color: textColor),
        label: Text('Улучшить', style: TextStyle(color: textColor)),
        onPressed: () {
          logger.i("Rewrite button pressed");
          processClipboardText(context, 'rewrite');
        },
      ),
    ];

    return fluent.CommandBarCard(
      backgroundColor: backgroundColor,
      child: fluent.CommandBar(
        primaryItems: [
          ...simpleCommandBarItems,
        ],
      ),
    );
  }
}
