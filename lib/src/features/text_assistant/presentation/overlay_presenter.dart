import 'dart:async';

import 'package:flutter/foundation.dart';

class OverlayPresenter {
  VoidCallback? _onShow;
  Future<bool> Function()? _ensureHostSurface;

  void attach(VoidCallback onShow) => _onShow = onShow;

  void detach(VoidCallback onShow) {
    if (identical(_onShow, onShow)) _onShow = null;
  }

  void attachHostGuard(Future<bool> Function() ensureHostSurface) =>
      _ensureHostSurface = ensureHostSurface;

  void detachHostGuard(Future<bool> Function() ensureHostSurface) {
    if (identical(_ensureHostSurface, ensureHostSurface)) {
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
