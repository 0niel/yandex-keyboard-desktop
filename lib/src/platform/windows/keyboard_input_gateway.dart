final class KeyboardStroke {
  const KeyboardStroke({required this.virtualKey, required this.isKeyUp});

  final int virtualKey;
  final bool isKeyUp;
}

abstract interface class KeyboardInputGateway {
  int send(List<KeyboardStroke> strokes);
}
