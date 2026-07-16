import 'package:flutter/widgets.dart';
import 'package:yandex_keyboard_desktop/src/app_ui/app_tokens.dart';

class AppSurface extends StatelessWidget {
  const AppSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.radius = AppRadius.surface,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: color ?? AppColors.surface(context),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Padding(padding: padding, child: child),
      );
}

class AppOverlaySurface extends StatelessWidget {
  const AppOverlaySurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.xs),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.overlay);
    final highContrast = MediaQuery.maybeOf(context)?.highContrast ?? false;
    if (highContrast) {
      return ClipRRect(
        borderRadius: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.overlayFallback(context),
            borderRadius: radius,
          ),
          child: Padding(padding: padding, child: child),
        ),
      );
    }

    final dark = AppColors.isDark(context);
    final glass = AppGlassScope.of(context);
    final fill = glass
        ? (dark
            ? const [Color(0xB81C1C21), Color(0xCC121216)]
            : const [Color(0xCCFFFFFF), Color(0xBAEFEFF4)])
        : (dark
            ? const [Color(0xF01D1D21), Color(0xF6141418)]
            : const [Color(0xF7FFFFFF), Color(0xF0F2F2F6)]);
    final rimTop = dark ? const Color(0x40FFFFFF) : const Color(0xB3FFFFFF);
    final rimBottom = dark ? const Color(0x14FFFFFF) : const Color(0x33FFFFFF);
    final glare = dark ? const Color(0x1FFFFFFF) : const Color(0x4DFFFFFF);

    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: fill,
              ),
              borderRadius: radius,
            ),
            child: Padding(padding: padding, child: child),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: const Alignment(0, 0.35),
                    colors: [glare, glare.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _GlassRimPainter(
                  radius: AppRadius.overlay,
                  top: rimTop,
                  bottom: rimBottom,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter({
    required this.radius,
    required this.top,
    required this.bottom,
  });

  final double radius;
  final Color top;
  final Color bottom;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [top, bottom],
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius - 0.5)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_GlassRimPainter oldDelegate) =>
      radius != oldDelegate.radius ||
      top != oldDelegate.top ||
      bottom != oldDelegate.bottom;
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
        'assets/brand/app_icon.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
      );
}

class AppSwap extends StatelessWidget {
  const AppSwap({
    super.key,
    required this.child,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: AppMotion.resolve(context, AppMotion.overlayEnter),
        reverseDuration: AppMotion.resolve(context, AppMotion.overlayExit),
        switchInCurve: AppMotion.enterCurve,
        switchOutCurve: AppMotion.exitCurve,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: alignment,
          children: [
            ...previousChildren,
            if (currentChild != null) currentChild
          ],
        ),
        transitionBuilder: (child, animation) {
          final entrance = CurvedAnimation(
            parent: animation,
            curve: AppMotion.enterCurve,
            reverseCurve: AppMotion.exitCurve,
          );
          return FadeTransition(
            opacity: entrance,
            child: AnimatedBuilder(
              animation: entrance,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, 2 * (1 - entrance.value)),
                child: child,
              ),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.985, end: 1).animate(entrance),
                alignment: Alignment.center,
                child: child,
              ),
            ),
          );
        },
        child: child,
      );
}
