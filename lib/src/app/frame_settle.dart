import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Completes after the next rendered frame so native window operations
/// (show/resize) never present a stale surface.
///
/// While the app window is hidden Flutter reports `AppLifecycleState.hidden`
/// and disables frame scheduling, so a plain `await endOfFrame` deadlocks
/// until something else makes the window visible. This helper forces a frame
/// in that state and additionally bounds the wait, so window orchestration
/// queues can never wedge permanently.
Future<void> settleFrame({
  Duration timeout = const Duration(milliseconds: 350),
}) {
  final binding = WidgetsBinding.instance;
  if (!binding.framesEnabled && binding.schedulerPhase == SchedulerPhase.idle) {
    binding.scheduleForcedFrame();
  }
  return binding.endOfFrame.timeout(timeout, onTimeout: () {});
}
