import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

class LoadingAnimation extends StatefulWidget {
  const LoadingAnimation({super.key});

  @override
  State<StatefulWidget> createState() => _LoadingAnimationState();
}

class _LoadingAnimationState extends State<LoadingAnimation> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat(reverse: true);
    _animation =
        Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = fluent.FluentTheme.of(context).brightness;
    final backgroundColor = brightness == Brightness.dark ? fluent.Colors.grey[170] : fluent.Colors.white;

    return fluent.CommandBarCard(
      backgroundColor: backgroundColor,
      child: Row(
        children: [
          const fluent.SizedBox(width: 32.0, height: 32.0, child: fluent.ProgressRing()),
          const SizedBox(width: 16.0),
          AnimatedBuilder(
            animation: _animation,
            builder: (context, child) {
              return fluent.Text(
                '${AppLocalizations.of(context)!.loading}${_getDots(_animation.value)}',
                style: fluent.Typography.fromBrightness(
                  brightness: brightness,
                ).body,
              );
            },
          ),
        ],
      ),
    );
  }

  String _getDots(double value) {
    int dotsCount = (value * 3).round();
    return '.' * dotsCount;
  }
}
