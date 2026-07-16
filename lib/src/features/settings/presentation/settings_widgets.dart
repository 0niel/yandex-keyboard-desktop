import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_controls.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_surface.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';

class SettingsPageScroll extends StatelessWidget {
  const SettingsPageScroll({
    super.key,
    required this.title,
    required this.description,
    required this.children,
  });

  final String title;
  final String description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
            sliver: SliverList.list(
              children: [
                Text(
                  title,
                  style: AppTextStyles.display(context),
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: AppTextStyles.body(context).copyWith(
                    color: AppColors.textSecondary(context),
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 24),
                for (var index = 0; index < children.length; index++) ...[
                  children[index],
                  if (index != children.length - 1) const SizedBox(height: 18),
                ],
              ],
            ),
          ),
        ],
      );
}

class SettingGroup extends StatelessWidget {
  const SettingGroup({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: AppTextStyles.caption(context).copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(AppRadius.surface),
            ),
            child: Column(
              children: [
                for (var index = 0; index < children.length; index++)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      index == 0 ? 14 : 8,
                      16,
                      index == children.length - 1 ? 14 : 8,
                    ),
                    child: children[index],
                  ),
              ],
            ),
          ),
        ],
      );
}

class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.label,
    this.description,
    required this.control,
  });

  final String label;
  final String? description;
  final Widget control;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 480;
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppTextStyles.body(context).copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (description != null) ...[
                const SizedBox(height: 3),
                Text(
                  description!,
                  style: AppTextStyles.caption(context),
                ),
              ],
            ],
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [text, const SizedBox(height: 10), control],
            );
          }
          return Row(
            children: [
              Expanded(child: text),
              const SizedBox(width: 20),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: control,
              ),
            ],
          );
        },
      );
}

class AppSelect<T> extends StatefulWidget {
  const AppSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  State<AppSelect<T>> createState() => _AppSelectState<T>();
}

class _AppSelectState<T> extends State<AppSelect<T>> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();

  void _close() {
    if (_portal.isShowing) _portal.hide();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
        child: CompositedTransformTarget(
          link: _link,
          child: OverlayPortal(
            controller: _portal,
            overlayChildBuilder: (context) => Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _close,
                  ),
                ),
                CompositedTransformFollower(
                  link: _link,
                  targetAnchor: Alignment.bottomLeft,
                  followerAnchor: Alignment.topLeft,
                  offset: const Offset(0, 6),
                  child: SizedBox(
                    width: 240,
                    child: AppSurface(
                      padding: const EdgeInsets.all(4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final entry in widget.items.entries)
                            AppButton(
                              label: entry.value,
                              kind: entry.key == widget.value
                                  ? AppButtonKind.primary
                                  : AppButtonKind.quiet,
                              onPressed: () {
                                _close();
                                widget.onChanged(entry.key);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            child: AppPressable(
              onPressed: _portal.toggle,
              backgroundColor: AppColors.surfaceMuted(context),
              hoverColor:
                  AppColors.textPrimary(context).withValues(alpha: 0.10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.items[widget.value] ?? '',
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body(context).copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(LucideIcons.chevronDown, size: 16),
                ],
              ),
            ),
          ),
        ),
      );
}

class AppSwitch extends StatelessWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => AppToggle(
        value: value,
        onChanged: onChanged,
        label: label,
      );
}

class InlineNotice extends StatelessWidget {
  const InlineNotice({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget? action;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted(context),
          borderRadius: BorderRadius.circular(AppRadius.surface),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: AppColors.brand),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.body(context).copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style:
                          AppTextStyles.caption(context).copyWith(height: 1.4),
                    ),
                  ],
                ),
              ),
              if (action != null) ...[
                const SizedBox(width: 12),
                action!,
              ],
            ],
          ),
        ),
      );
}
