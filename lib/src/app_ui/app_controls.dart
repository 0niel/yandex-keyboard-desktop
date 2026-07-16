import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_surface.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';

abstract final class AppTextStyles {
  static TextStyle display(BuildContext context) => TextStyle(
        color: AppColors.textPrimary(context),
        fontSize: 24,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
      );

  static TextStyle title(BuildContext context) => TextStyle(
        color: AppColors.textPrimary(context),
        fontSize: 15,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.15,
      );

  static TextStyle body(BuildContext context) => TextStyle(
        color: AppColors.textPrimary(context),
        fontSize: 13,
        height: 1.35,
        fontWeight: FontWeight.w400,
      );

  static TextStyle label(BuildContext context) => TextStyle(
        color: AppColors.textPrimary(context),
        fontSize: 12.5,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
      );

  static TextStyle caption(BuildContext context) => TextStyle(
        color: AppColors.textSecondary(context),
        fontSize: 12,
        height: 1.35,
      );
}

class AppPressable extends StatefulWidget {
  const AppPressable({
    super.key,
    required this.child,
    required this.onPressed,
    required this.backgroundColor,
    this.hoverColor,
    this.focusColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.radius = AppRadius.control,
    this.semanticLabel,
    this.toggled,
    this.autofocus = false,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final Color backgroundColor;
  final Color? hoverColor;
  final Color? focusColor;
  final EdgeInsetsGeometry padding;
  final double radius;
  final String? semanticLabel;
  final bool? toggled;
  final bool autofocus;

  @override
  State<AppPressable> createState() => _AppPressableState();
}

class _AppPressableState extends State<AppPressable> {
  var _hovered = false;
  var _focused = false;
  var _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final color = !enabled
        ? widget.backgroundColor.withValues(alpha: 0.55)
        : _hovered
            ? widget.hoverColor ?? widget.backgroundColor
            : _focused
                ? widget.focusColor ??
                    widget.hoverColor ??
                    widget.backgroundColor
                : widget.backgroundColor;
    final duration = AppMotion.resolve(context, AppMotion.hover);
    final content = AnimatedScale(
      scale: enabled && _pressed ? 0.985 : 1,
      duration: duration,
      curve: _pressed ? AppMotion.enterCurve : AppMotion.exitCurve,
      child: AnimatedContainer(
        duration: duration,
        curve: AppMotion.enterCurve,
        padding: widget.padding,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(widget.radius),
        ),
        child: widget.child,
      ),
    );
    return Semantics(
      button: widget.toggled == null,
      toggled: widget.toggled,
      enabled: enabled,
      label: widget.semanticLabel,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter):
              widget.onPressed ?? () {},
          const SingleActivator(LogicalKeyboardKey.space):
              widget.onPressed ?? () {},
        },
        child: Focus(
          autofocus: widget.autofocus,
          canRequestFocus: enabled,
          onFocusChange: (value) => setState(() => _focused = value),
          child: MouseRegion(
            cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
            onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
            onExit: enabled ? (_) => setState(() => _hovered = false) : null,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown:
                  enabled ? (_) => setState(() => _pressed = true) : null,
              onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
              onTapCancel:
                  enabled ? () => setState(() => _pressed = false) : null,
              onTap: widget.onPressed,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

enum AppButtonKind { primary, quiet, danger }

class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = AppButtonKind.quiet,
    this.compact = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final AppButtonKind kind;
  final bool compact;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final dark = AppColors.isDark(context);
    final (background, hover, focus, foreground) = switch (kind) {
      AppButtonKind.primary => (
          dark ? const Color(0xFFF5F5F5) : const Color(0xFF171717),
          dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
          dark ? const Color(0xFFEBEBEB) : const Color(0xFF262626),
          dark ? const Color(0xFF161616) : const Color(0xFFFFFFFF),
        ),
      AppButtonKind.danger => (
          AppColors.danger.withValues(alpha: 0.14),
          AppColors.danger.withValues(alpha: 0.22),
          AppColors.danger.withValues(alpha: 0.18),
          AppColors.danger,
        ),
      AppButtonKind.quiet => (
          AppColors.surfaceMuted(context),
          dark ? const Color(0xFF34343A) : const Color(0xFFE2E2DD),
          dark ? const Color(0xFF2C2C31) : const Color(0xFFE9E9E5),
          AppColors.textPrimary(context),
        ),
    };
    return AppPressable(
      onPressed: onPressed,
      backgroundColor: background,
      hoverColor: hover,
      focusColor: focus,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 13,
        vertical: compact ? 5 : 9,
      ),
      semanticLabel: label,
      autofocus: autofocus,
      child: DefaultTextStyle(
        style: AppTextStyles.label(context).copyWith(
          color: onPressed == null
              ? foreground.withValues(alpha: 0.45)
              : foreground,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: 7),
            ],
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }
}

class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.size = 18,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => AppPressable(
        onPressed: onPressed,
        semanticLabel: label,
        backgroundColor: const Color(0x00000000),
        hoverColor: AppColors.textPrimary(context).withValues(alpha: 0.08),
        focusColor: AppColors.textPrimary(context).withValues(alpha: 0.10),
        autofocus: autofocus,
        padding: const EdgeInsets.all(8),
        child: Icon(
          icon,
          size: size,
          color: onPressed == null
              ? AppColors.textSecondary(context).withValues(alpha: 0.45)
              : AppColors.textSecondary(context),
        ),
      );
}

class AppToggle extends StatelessWidget {
  const AppToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) => AppPressable(
        onPressed: onChanged == null ? null : () => onChanged!(!value),
        semanticLabel: label,
        toggled: value,
        backgroundColor:
            value ? AppColors.brand : AppColors.surfaceMuted(context),
        hoverColor: value
            ? AppColors.brand.withValues(alpha: 0.88)
            : AppColors.textPrimary(context).withValues(alpha: 0.12),
        padding: const EdgeInsets.all(3),
        radius: AppRadius.pill,
        child: SizedBox(
          width: 32,
          height: 16,
          child: AnimatedAlign(
            duration: AppMotion.resolve(context, AppMotion.control),
            curve: AppMotion.enterCurve,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: value
                    ? const Color(0xFFFFFFFF)
                    : AppColors.textSecondary(context),
                shape: BoxShape.circle,
              ),
              child: const SizedBox.square(dimension: 16),
            ),
          ),
        ),
      );
}

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required String barrierLabel,
  bool dismissible = true,
}) {
  final duration = AppMotion.resolve(context, AppMotion.content);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: barrierLabel,
    barrierColor: const Color(0x99000000),
    transitionDuration: duration,
    pageBuilder: (context, _, __) => Center(child: builder(context)),
    transitionBuilder: (context, animation, _, child) {
      if (duration == Duration.zero) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.enterCurve,
        reverseCurve: AppMotion.exitCurve,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.012),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.width = 460,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;
  final double width;

  @override
  Widget build(BuildContext context) => Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: title,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: 560),
          child: AppSurface(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: DefaultTextStyle(
              style: AppTextStyles.body(context),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title, style: AppTextStyles.title(context)),
                  const SizedBox(height: 14),
                  Flexible(child: content),
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: actions,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.initialValue,
    this.onChanged,
    this.onSubmitted,
    this.readOnly = false,
    this.autofocus = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.maxLength,
    this.hintText,
  }) : assert(controller == null || initialValue == null);

  final TextEditingController? controller;
  final String? initialValue;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool readOnly;
  final bool autofocus;
  final int minLines;
  final int? maxLines;
  final int? maxLength;
  final String? hintText;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController(text: widget.initialValue);
  late final FocusNode _focusNode = FocusNode()..addListener(_onFocusChanged);

  void _onFocusChanged() => setState(() {});

  @override
  void dispose() {
    _focusNode.dispose();
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _focusNode.requestFocus,
        child: AnimatedContainer(
          duration: AppMotion.resolve(context, AppMotion.hover),
          curve: AppMotion.enterCurve,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _focusNode.hasFocus
                ? AppColors.brand.withValues(alpha: 0.08)
                : AppColors.surfaceMuted(context),
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Stack(
            children: [
              if (_controller.text.isEmpty && widget.hintText != null)
                IgnorePointer(
                  child: Text(
                    widget.hintText!,
                    style: AppTextStyles.body(context).copyWith(
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                ),
              EditableText(
                controller: _controller,
                focusNode: _focusNode,
                style: AppTextStyles.body(context),
                cursorColor: AppColors.brand,
                backgroundCursorColor: AppColors.textSecondary(context),
                selectionColor: AppColors.brand.withValues(alpha: 0.24),
                readOnly: widget.readOnly,
                autofocus: widget.autofocus,
                minLines: widget.minLines,
                maxLines: widget.maxLines,
                keyboardType: widget.maxLines == 1
                    ? TextInputType.text
                    : TextInputType.multiline,
                textInputAction: widget.maxLines == 1
                    ? TextInputAction.done
                    : TextInputAction.newline,
                inputFormatters: widget.maxLength == null
                    ? null
                    : [LengthLimitingTextInputFormatter(widget.maxLength)],
                onChanged: (value) {
                  setState(() {});
                  widget.onChanged?.call(value);
                },
                onSubmitted: widget.onSubmitted,
              ),
            ],
          ),
        ),
      );
}
