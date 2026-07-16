import 'package:flutter/foundation.dart';

class OverlayPresenter {
  VoidCallback? _onShow;

  void attach(VoidCallback onShow) => _onShow = onShow;

  void detach(VoidCallback onShow) {
    if (identical(_onShow, onShow)) _onShow = null;
  }

  void show() => _onShow?.call();
}
