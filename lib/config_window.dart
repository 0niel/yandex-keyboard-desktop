import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yandex_keyboard_desktop/config_manager.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/hotkey_service.dart';

class ConfigWindow extends StatefulWidget {
  const ConfigWindow({super.key});

  @override
  State<ConfigWindow> createState() => _ConfigWindowState();
}

class _ConfigWindowState extends State<ConfigWindow> {
  late TextEditingController _hotkeyController;
  late bool _autostart;
  late HotKeyService _hotKeyService;
  HotKey? _currentHotKey;

  @override
  void initState() {
    super.initState();
    _autostart = false;
    _hotkeyController = TextEditingController();
    _hotKeyService = HotKeyService();

    _loadConfig();
  }

  @override
  void dispose() {
    _hotkeyController.dispose();
    _hotKeyService.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final config = await ConfigManager.loadConfig();
    setState(() {
      _hotkeyController.text = _formatHotKey(
        config['hotkey']['key'],
        List<String>.from(config['hotkey']['modifiers']),
      );
      _autostart = config['autostart'];
      _currentHotKey = HotKey(
        key: HotKeyService.getPhysicalKey(config['hotkey']['key']),
        modifiers: List<HotKeyModifier>.from(config['hotkey']['modifiers'].map((m) => HotKeyService.getModifierKey(m))),
      );
    });
  }

  Future<void> _saveConfig() async {
    final config = {
      'hotkey': {
        'key': _currentHotKey?.key.keyLabel.split('.').last ?? 'KeyR',
        'modifiers': _currentHotKey?.modifiers?.map((m) => m.toString().split('.').last).toList() ?? ['Control'],
      },
      'autostart': _autostart,
    };
    await ConfigManager.saveConfig(config);
  }

  void _setHotKey(HotKey hotkey) {
    setState(() {
      _hotkeyController.text = _formatHotKey(
        hotkey.key.keyLabel,
        hotkey.modifiers?.map((m) => m.toString().split('.').last).toList() ?? [],
      );
      _currentHotKey = hotkey;
    });
    _hotKeyService.setHotKey(
      key: hotkey.key.keyLabel,
      modifiers: hotkey.modifiers?.map((m) => m.toString().split('.').last).toList() ?? ['Control'],
      onHotKeyPressed: () {
        print('Hotkey pressed');
      },
    );
  }

  String _formatHotKey(String key, List<String> modifiers) {
    final keyString = HotKeyService.mapKeyToString(key);
    final modifiersString = modifiers.map(HotKeyService.mapModifierToString).join(' + ');
    return '$modifiersString + $keyString';
  }

  Widget _buildHotKeyWidget(String key, List<String> modifiers) {
    final List<Widget> widgets = [];
    for (var modifier in modifiers) {
      widgets.add(Row(
        children: [
          HotKeyService.mapModifierToIcon(modifier),
          const SizedBox(width: 4),
          Text(HotKeyService.mapModifierToString(modifier), style: const fluent.Typography.raw().body),
        ],
      ));
      widgets.add(Text(' + ', style: const fluent.Typography.raw().body));
    }
    widgets.add(Text(HotKeyService.mapKeyToString(key), style: const fluent.Typography.raw().body));
    return Row(children: widgets);
  }

  @override
  Widget build(BuildContext context) {
    return fluent.NavigationView(
      appBar: fluent.NavigationAppBar(
        title: Text(AppLocalizations.of(context)!.config),
        leading: IconButton(
          icon: const Icon(fluent.FluentIcons.cancel),
          onPressed: () => windowManager.hide(),
        ),
      ),
      content: fluent.ScaffoldPage(
        content: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              fluent.InfoBar(
                title: Text(AppLocalizations.of(context)!.config),
                content: Text(AppLocalizations.of(context)!.configDescription),
                severity: fluent.InfoBarSeverity.info,
              ),
              const SizedBox(height: 16),
              fluent.ToggleSwitch(
                checked: _autostart,
                onChanged: (value) {
                  setState(() {
                    _autostart = value;
                  });
                },
                content: Text(AppLocalizations.of(context)!.autostart),
              ),
              const SizedBox(height: 16),
              fluent.Text(AppLocalizations.of(context)!.hotkey, style: fluent.FluentTheme.of(context).typography.body),
              fluent.Button(
                child: _hotkeyController.text.isEmpty
                    ? Text(AppLocalizations.of(context)!.setHotkey)
                    : _buildHotKeyWidget(
                        _currentHotKey?.key.keyLabel ?? '',
                        _currentHotKey?.modifiers?.map((m) => m.toString().split('.').last).toList() ?? [],
                      ),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => HotKeyDialog(
                      onHotKeySet: _setHotKey,
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              fluent.Button(
                child: Text(AppLocalizations.of(context)!.save),
                onPressed: () async {
                  await _saveConfig();
                  windowManager.hide();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HotKeyDialog extends StatefulWidget {
  final Function(HotKey hotkey) onHotKeySet;

  const HotKeyDialog({super.key, required this.onHotKeySet});

  @override
  State<HotKeyDialog> createState() => _HotKeyDialogState();
}

class _HotKeyDialogState extends State<HotKeyDialog> {
  PhysicalKeyboardKey? _key;
  final Set<LogicalKeyboardKey> _modifiers = {};

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.alt,
          LogicalKeyboardKey.keyS,
        ): const SaveHotkeyIntent(),
      },
      child: Actions(
        actions: {
          SaveHotkeyIntent: CallbackAction<SaveHotkeyIntent>(
            onInvoke: (SaveHotkeyIntent intent) {
              final hotkey = HotKey(
                key: _key!,
                modifiers: _modifiers.map((k) => HotKeyService.getModifierKey(k.debugName!)).toList(),
              );
              widget.onHotKeySet(hotkey);
              Navigator.of(context).pop();
              return null;
            },
          ),
        },
        child: fluent.ContentDialog(
          title: Text(AppLocalizations.of(context)!.setHotkey),
          content: Text(AppLocalizations.of(context)!.pressHotkey),
          actions: [
            fluent.Button(
              child: Text(AppLocalizations.of(context)!.save),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
          event.logicalKey == LogicalKeyboardKey.shiftLeft ||
          event.logicalKey == LogicalKeyboardKey.altLeft ||
          event.logicalKey == LogicalKeyboardKey.metaLeft ||
          event.logicalKey == LogicalKeyboardKey.controlRight ||
          event.logicalKey == LogicalKeyboardKey.shiftRight ||
          event.logicalKey == LogicalKeyboardKey.altRight ||
          event.logicalKey == LogicalKeyboardKey.metaRight) {
        setState(() {
          _modifiers.add(event.logicalKey);
        });
      } else {
        setState(() {
          _key = event.physicalKey;
        });
      }
    } else if (event is KeyUpEvent) {
      if (_key != null && _modifiers.isNotEmpty) {
        final hotkey = HotKey(
          key: _key!,
          modifiers: _modifiers.map((k) => HotKeyService.getModifierKey(k.debugName!)).toList(),
        );
        widget.onHotKeySet(hotkey);
        HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
        Navigator.of(context).pop();
      }
    }
    return false; // To indicate that the event was not handled and should propagate further.
  }
}

class SaveHotkeyIntent extends Intent {
  const SaveHotkeyIntent();
}
