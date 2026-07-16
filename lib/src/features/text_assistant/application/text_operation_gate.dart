final class TextOperationGate {
  int _nextGeneration = 0;
  int? _activeGeneration;

  bool get isActive => _activeGeneration != null;

  TextOperationPermit? tryAcquire() {
    if (_activeGeneration != null) return null;
    final generation = ++_nextGeneration;
    _activeGeneration = generation;
    return TextOperationPermit._(this, generation);
  }

  void reset() {
    _activeGeneration = null;
  }

  void _release(int generation) {
    if (_activeGeneration == generation) {
      _activeGeneration = null;
    }
  }
}

final class TextOperationPermit {
  TextOperationPermit._(this._gate, this._generation);

  final TextOperationGate _gate;
  final int _generation;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _gate._release(_generation);
  }
}
