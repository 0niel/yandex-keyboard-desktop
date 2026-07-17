import 'dart:async';

import 'package:flutter/foundation.dart';

class OverlayPresenter {
  VoidCallback? _onShow;
  Future<bool> Function()? _ensureHostSurface;

  // Note: comparisons use == rather than identical(): attach/detach receive
  // fresh tear-offs of the same instance method, which are equal but never
  // identical. With identical() a disposed overlay could never detach itself,
  // leaving _onShow pointing at a defunct State (so hotkeys silently no-op).
  void attach(VoidCallback onShow) => _onShow = onShow;

  void detach(VoidCallback onShow) {
    if (_onShow == onShow) _onShow = null;
  }

  void attachHostGuard(Future<bool> Function() ensureHostSurface) =>
      _ensureHostSurface = ensureHostSurface;

  void detachHostGuard(Future<bool> Function() ensureHostSurface) {
    if (_ensureHostSurface == ensureHostSurface) {
      _ensureHostSurface = null;
    }
  }

  Future<bool> ensureHostSurface() async =>
      await _ensureHostSurface?.call() ?? true;

  void show() {
    final onShow = _onShow;
    if (onShow != null) {
      onShow();
      return;
    }
    unawaited(
      ensureHostSurface().then((ready) {
        if (ready) _onShow?.call();
      }),
    );
  }
}
