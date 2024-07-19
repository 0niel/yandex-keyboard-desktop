import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';

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
    return SizedBox(
      child: fluent.CommandBarCard(
        backgroundColor: fluent.Colors.white,
        child: Row(
          children: [
            const fluent.SizedBox(width: 32.0, height: 32.0, child: fluent.ProgressRing()),
            const SizedBox(width: 8.0),
            fluent.Text(
              'Загрузка${_getDots(_animation.value)}',
            ),
          ],
        ),
      ),
    );
  }

  String _getDots(double value) {
    int dotsCount = (value * 3).round();
    return '.' * dotsCount;
  }
}
