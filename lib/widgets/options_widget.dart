import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:yandex_keyboard_desktop/bloc/text_processing_type.dart';

class OptionsWidget extends StatelessWidget {
  final Future<void> Function(BuildContext context, TextProcessingType type) processClipboardText;

  const OptionsWidget({
    super.key,
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
          processClipboardText(context, TextProcessingType.emojify);
        },
      ),
      fluent.CommandBarButton(
        icon: Icon(fluent.FluentIcons.edit, color: textColor),
        label: Text('Улучшить', style: TextStyle(color: textColor)),
        onPressed: () {
          processClipboardText(context, TextProcessingType.rewrite);
        },
      ),
      fluent.CommandBarButton(
        icon: Icon(fluent.FluentIcons.settings, color: textColor),
        label: Text('Исправить', style: TextStyle(color: textColor)),
        onPressed: () {
          processClipboardText(context, TextProcessingType.fix);
        },
      ),
    ];

    return fluent.CommandBarCard(
      backgroundColor: backgroundColor,
      child: fluent.CommandBar(
        isCompact: false,
        overflowBehavior: fluent.CommandBarOverflowBehavior.clip,
        primaryItems: [
          ...simpleCommandBarItems,
        ],
      ),
    );
  }
}
