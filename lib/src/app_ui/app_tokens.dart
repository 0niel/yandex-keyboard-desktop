import 'package:flutter/widgets.dart';

class AppThemeScope extends InheritedWidget {
  const AppThemeScope({
    super.key,
    required this.brightness,
    required super.child,
  });

  final Brightness brightness;

  static AppThemeScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppThemeScope>();

  @override
  bool updateShouldNotify(AppThemeScope oldWidget) =>
      brightness != oldWidget.brightness;
}

class AppGlassScope extends InheritedWidget {
  const AppGlassScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppGlassScope>()?.enabled ??
      false;

  @override
  bool updateShouldNotify(AppGlassScope oldWidget) =>
      enabled != oldWidget.enabled;
}

abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
}

abstract final class AppRadius {
  static const double control = 8;
  static const double surface = 14;
  static const double overlay = 12;
  static const double pill = 999;
}

abstract final class AppMotion {
  static const Duration hover = Duration(milliseconds: 90);
  static const Duration control = Duration(milliseconds: 140);
  static const Duration content = Duration(milliseconds: 180);
  static const Duration overlayEnter = Duration(milliseconds: 140);
  static const Duration overlayExit = Duration(milliseconds: 90);
  static const Curve enterCurve = Curves.easeOutCubic;
  static const Curve exitCurve = Curves.easeInCubic;

  static bool disabled(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  static Duration resolve(BuildContext context, Duration duration) =>
      disabled(context) ? Duration.zero : duration;
}

abstract final class AppColors {
  static const Color brand = Color(0xFFFF0032);
  static const Color success = Color(0xFF1A9C61);
  static const Color warning = Color(0xFFD98218);
  static const Color danger = Color(0xFFE23D49);

  static Color canvasFor(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFF0F0F10)
      : const Color(0xFFF5F5F3);

  static bool isDark(BuildContext context) =>
      (AppThemeScope.maybeOf(context)?.brightness ??
          MediaQuery.maybeOf(context)?.platformBrightness ??
          Brightness.light) ==
      Brightness.dark;

  static Color canvas(BuildContext context) => canvasFor(
        isDark(context) ? Brightness.dark : Brightness.light,
      );

  static Color sidebar(BuildContext context) =>
      isDark(context) ? const Color(0xFF141415) : const Color(0xFFECECEA);

  static Color surface(BuildContext context) =>
      isDark(context) ? const Color(0xFF1A1A1B) : const Color(0xFFFFFFFF);

  static Color surfaceMuted(BuildContext context) =>
      isDark(context) ? const Color(0xFF242425) : const Color(0xFFEFEFED);

  static Color textPrimary(BuildContext context) =>
      isDark(context) ? const Color(0xFFF5F5F5) : const Color(0xFF161616);

  static Color textSecondary(BuildContext context) =>
      isDark(context) ? const Color(0xFFA8A8AA) : const Color(0xFF6A6A6A);

  static Color overlayFallback(BuildContext context) =>
      isDark(context) ? const Color(0xFF181819) : const Color(0xFFFDFDFC);
}
