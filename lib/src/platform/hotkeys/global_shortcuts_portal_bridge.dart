import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';

final class GlobalShortcutsCapability extends Equatable {
  const GlobalShortcutsCapability({
    required this.available,
    required this.version,
  }) : assert(version >= 0);

  factory GlobalShortcutsCapability.fromMap(Map<Object?, Object?> map) {
    final available = _requiredBool(map, 'available');
    final version = _requiredNonNegativeInt(map, 'version');
    if (available && version == 0) {
      throw const FormatException(
        'An available GlobalShortcuts portal must report a version.',
      );
    }
    return GlobalShortcutsCapability(
      available: available,
      version: version,
    );
  }

  final bool available;
  final int version;

  @override
  List<Object?> get props => [available, version];
}

final class PortalShortcutDefinition extends Equatable {
  PortalShortcutDefinition({
    required String id,
    required String description,
    required String preferredTrigger,
  })  : id = _validateNonEmpty(id, 'shortcut id'),
        description = _validateNonEmpty(description, 'shortcut description'),
        preferredTrigger =
            _validateNonEmpty(preferredTrigger, 'preferred trigger');

  final String id;
  final String description;
  final String preferredTrigger;

  Map<String, Object> toMap() => {
        'id': id,
        'description': description,
        'preferredTrigger': preferredTrigger,
      };

  @override
  List<Object?> get props => [id, description, preferredTrigger];
}

final class PortalCandidateSession extends Equatable {
  PortalCandidateSession({required String id, required this.generation})
      : id = _validateNonEmpty(id, 'candidate session id') {
    if (generation < 1) {
      throw const FormatException('Candidate generation must be positive.');
    }
  }

  factory PortalCandidateSession.fromMap(Map<Object?, Object?> map) =>
      PortalCandidateSession(
        id: _requiredNonEmptyString(map, 'id'),
        generation: _requiredPositiveInt(map, 'generation'),
      );

  final String id;
  final int generation;

  Map<String, Object> toMap() => {'id': id, 'generation': generation};

  @override
  List<Object?> get props => [id, generation];
}

final class PortalShortcutBinding extends Equatable {
  PortalShortcutBinding({
    required String id,
    required String description,
    this.triggerDescription,
  })  : id = _validateNonEmpty(id, 'bound shortcut id'),
        description = _validateNonEmpty(description, 'bound description') {
    if (triggerDescription != null && triggerDescription!.isEmpty) {
      throw const FormatException('Trigger description must not be empty.');
    }
  }

  factory PortalShortcutBinding.fromMap(Map<Object?, Object?> map) {
    final triggerDescription = map['triggerDescription'];
    if (triggerDescription != null && triggerDescription is! String) {
      throw const FormatException('Invalid triggerDescription.');
    }
    return PortalShortcutBinding(
      id: _requiredNonEmptyString(map, 'id'),
      description: _requiredNonEmptyString(map, 'description'),
      triggerDescription: triggerDescription as String?,
    );
  }

  final String id;
  final String description;
  final String? triggerDescription;

  @override
  List<Object?> get props => [id, description, triggerDescription];
}

enum PortalBindStatus { success, cancelled, failed }

final class PortalBindResult extends Equatable {
  PortalBindResult({
    required this.status,
    required List<PortalShortcutBinding> bindings,
    this.diagnosticCode,
  }) : bindings = List.unmodifiable(bindings);

  factory PortalBindResult.fromMap(Map<Object?, Object?> map) {
    final status = switch (_requiredNonEmptyString(map, 'status')) {
      'success' => PortalBindStatus.success,
      'cancelled' => PortalBindStatus.cancelled,
      'failed' => PortalBindStatus.failed,
      _ => throw const FormatException('Unknown portal bind status.'),
    };
    final rawBindings = map['bindings'];
    if (rawBindings is! List<Object?>) {
      throw const FormatException('Invalid portal binding list.');
    }
    final diagnosticCode = map['diagnosticCode'];
    if (diagnosticCode != null && diagnosticCode is! String) {
      throw const FormatException('Invalid portal diagnostic code.');
    }
    return PortalBindResult(
      status: status,
      bindings: rawBindings.map((value) {
        if (value is! Map<Object?, Object?>) {
          throw const FormatException('Invalid portal binding.');
        }
        return PortalShortcutBinding.fromMap(value);
      }).toList(),
      diagnosticCode: diagnosticCode as String?,
    );
  }

  final PortalBindStatus status;
  final List<PortalShortcutBinding> bindings;
  final String? diagnosticCode;

  @override
  List<Object?> get props => [status, bindings, diagnosticCode];
}

sealed class GlobalShortcutsPortalEvent extends Equatable {
  const GlobalShortcutsPortalEvent({required this.generation});

  factory GlobalShortcutsPortalEvent.fromMap(Map<Object?, Object?> map) {
    final type = _requiredNonEmptyString(map, 'type');
    return switch (type) {
      'activated' => PortalShortcutActivated.fromMap(map),
      'deactivated' => PortalShortcutDeactivated.fromMap(map),
      'shortcutsChanged' => PortalShortcutsChanged.fromMap(map),
      'sessionClosed' => PortalSessionClosed.fromMap(map),
      'availabilityChanged' => PortalAvailabilityChanged.fromMap(map),
      _ => throw FormatException('Unknown GlobalShortcuts event: $type'),
    };
  }

  final int generation;
}

final class PortalShortcutActivated extends GlobalShortcutsPortalEvent {
  PortalShortcutActivated({
    required super.generation,
    required String shortcutId,
    required this.timestamp,
    this.activationToken,
  }) : shortcutId = _validateNonEmpty(shortcutId, 'activated shortcut id') {
    if (generation < 1 || timestamp < 0) {
      throw const FormatException('Invalid shortcut activation metadata.');
    }
    if (activationToken != null && activationToken!.isEmpty) {
      throw const FormatException('Activation token must not be empty.');
    }
  }

  factory PortalShortcutActivated.fromMap(Map<Object?, Object?> map) {
    final activationToken = map['activationToken'];
    if (activationToken != null && activationToken is! String) {
      throw const FormatException('Invalid activation token.');
    }
    return PortalShortcutActivated(
      generation: _requiredPositiveInt(map, 'generation'),
      shortcutId: _requiredNonEmptyString(map, 'shortcutId'),
      timestamp: _requiredNonNegativeInt(map, 'timestamp'),
      activationToken: activationToken as String?,
    );
  }

  final String shortcutId;
  final int timestamp;
  final String? activationToken;

  @override
  List<Object?> get props => [
        generation,
        shortcutId,
        timestamp,
        activationToken,
      ];
}

final class PortalShortcutDeactivated extends GlobalShortcutsPortalEvent {
  PortalShortcutDeactivated({
    required super.generation,
    required String shortcutId,
    required this.timestamp,
  }) : shortcutId = _validateNonEmpty(shortcutId, 'deactivated shortcut id') {
    if (generation < 1 || timestamp < 0) {
      throw const FormatException('Invalid shortcut deactivation metadata.');
    }
  }

  factory PortalShortcutDeactivated.fromMap(Map<Object?, Object?> map) =>
      PortalShortcutDeactivated(
        generation: _requiredPositiveInt(map, 'generation'),
        shortcutId: _requiredNonEmptyString(map, 'shortcutId'),
        timestamp: _requiredNonNegativeInt(map, 'timestamp'),
      );

  final String shortcutId;
  final int timestamp;

  @override
  List<Object?> get props => [generation, shortcutId, timestamp];
}

final class PortalShortcutsChanged extends GlobalShortcutsPortalEvent {
  PortalShortcutsChanged({
    required super.generation,
    required List<PortalShortcutBinding> bindings,
  }) : bindings = List.unmodifiable(bindings) {
    if (generation < 1) {
      throw const FormatException('Invalid shortcuts-changed generation.');
    }
  }

  factory PortalShortcutsChanged.fromMap(Map<Object?, Object?> map) =>
      PortalShortcutsChanged(
        generation: _requiredPositiveInt(map, 'generation'),
        bindings: _requiredBindings(map),
      );

  final List<PortalShortcutBinding> bindings;

  @override
  List<Object?> get props => [generation, bindings];
}

final class PortalSessionClosed extends GlobalShortcutsPortalEvent {
  PortalSessionClosed({required super.generation, this.reason}) {
    if (generation < 1 || (reason != null && reason!.isEmpty)) {
      throw const FormatException('Invalid closed-session event.');
    }
  }

  factory PortalSessionClosed.fromMap(Map<Object?, Object?> map) {
    final reason = map['reason'];
    if (reason != null && reason is! String) {
      throw const FormatException('Invalid session close reason.');
    }
    return PortalSessionClosed(
      generation: _requiredPositiveInt(map, 'generation'),
      reason: reason as String?,
    );
  }

  final String? reason;

  @override
  List<Object?> get props => [generation, reason];
}

final class PortalAvailabilityChanged extends GlobalShortcutsPortalEvent {
  const PortalAvailabilityChanged({
    required super.generation,
    required this.capability,
  });

  factory PortalAvailabilityChanged.fromMap(Map<Object?, Object?> map) {
    final capability = map['capability'];
    if (capability is! Map<Object?, Object?>) {
      throw const FormatException('Invalid portal capability event.');
    }
    return PortalAvailabilityChanged(
      generation: _requiredNonNegativeInt(map, 'generation'),
      capability: GlobalShortcutsCapability.fromMap(capability),
    );
  }

  final GlobalShortcutsCapability capability;

  @override
  List<Object?> get props => [generation, capability];
}

abstract interface class GlobalShortcutsPortalBridge {
  Stream<GlobalShortcutsPortalEvent> get events;

  Future<GlobalShortcutsCapability> getCapability();

  Future<PortalCandidateSession> createCandidate({
    required int generation,
    required List<PortalShortcutDefinition> shortcuts,
  });

  Future<PortalBindResult> bindCandidate(PortalCandidateSession candidate);

  Future<void> commitCandidate(PortalCandidateSession candidate);

  Future<void> discardCandidate(PortalCandidateSession candidate);

  Future<void> cancelPendingRequest();

  Future<void> closeSessions();

  Future<void> configureShortcuts();

  Future<void> dispose();
}

final class MethodChannelGlobalShortcutsPortalBridge
    implements GlobalShortcutsPortalBridge {
  MethodChannelGlobalShortcutsPortalBridge({
    MethodChannel methodChannel = const MethodChannel(_methodChannelName),
    EventChannel eventChannel = const EventChannel(_eventChannelName),
    Stream<Object?>? rawEvents,
  })  : _methodChannel = methodChannel,
        _rawEvents = rawEvents ?? eventChannel.receiveBroadcastStream();

  static const _methodChannelName =
      'io.github.oniel.yandex_keyboard_desktop/global_shortcuts';
  static const _eventChannelName =
      'io.github.oniel.yandex_keyboard_desktop/global_shortcuts_events';

  final MethodChannel _methodChannel;
  final Stream<Object?> _rawEvents;
  Stream<GlobalShortcutsPortalEvent>? _events;

  @override
  Stream<GlobalShortcutsPortalEvent> get events => _events ??= _rawEvents.map(
        (value) {
          if (value is! Map<Object?, Object?>) {
            throw const FormatException('Invalid GlobalShortcuts event.');
          }
          return GlobalShortcutsPortalEvent.fromMap(value);
        },
      ).asBroadcastStream();

  @override
  Future<GlobalShortcutsCapability> getCapability() async =>
      GlobalShortcutsCapability.fromMap(
        await _requiredMap('getGlobalShortcutsCapability'),
      );

  @override
  Future<PortalCandidateSession> createCandidate({
    required int generation,
    required List<PortalShortcutDefinition> shortcuts,
  }) async {
    if (generation < 1) {
      throw ArgumentError.value(
        0,
        'generation',
        'Generation must be positive.',
      );
    }
    return PortalCandidateSession.fromMap(
      await _requiredMap('createGlobalShortcutsCandidate', {
        'generation': generation,
        'shortcuts': shortcuts.map((value) => value.toMap()).toList(),
      }),
    );
  }

  @override
  Future<PortalBindResult> bindCandidate(
    PortalCandidateSession candidate,
  ) async =>
      PortalBindResult.fromMap(
        await _requiredMap(
          'bindGlobalShortcutsCandidate',
          candidate.toMap(),
        ),
      );

  @override
  Future<void> commitCandidate(PortalCandidateSession candidate) =>
      _methodChannel.invokeMethod<void>(
        'commitGlobalShortcutsCandidate',
        candidate.toMap(),
      );

  @override
  Future<void> discardCandidate(PortalCandidateSession candidate) =>
      _methodChannel.invokeMethod<void>(
        'discardGlobalShortcutsCandidate',
        candidate.toMap(),
      );

  @override
  Future<void> cancelPendingRequest() =>
      _methodChannel.invokeMethod<void>('cancelGlobalShortcutsRequest');

  @override
  Future<void> closeSessions() =>
      _methodChannel.invokeMethod<void>('closeGlobalShortcutsSessions');

  @override
  Future<void> configureShortcuts() =>
      _methodChannel.invokeMethod<void>('configureGlobalShortcuts');

  @override
  Future<void> dispose() =>
      _methodChannel.invokeMethod<void>('disposeGlobalShortcuts');

  Future<Map<Object?, Object?>> _requiredMap(
    String method, [
    Object? arguments,
  ]) async {
    final value = await _methodChannel.invokeMethod<Object?>(method, arguments);
    if (value is! Map<Object?, Object?>) {
      throw FormatException('Invalid $method response.');
    }
    return value;
  }
}

List<PortalShortcutBinding> _requiredBindings(Map<Object?, Object?> map) {
  final rawBindings = map['bindings'];
  if (rawBindings is! List<Object?>) {
    throw const FormatException('Invalid portal binding list.');
  }
  return rawBindings.map((value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('Invalid portal binding.');
    }
    return PortalShortcutBinding.fromMap(value);
  }).toList();
}

String _requiredNonEmptyString(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throw FormatException('Invalid $key.');
  }
  return _validateNonEmpty(value, key);
}

String _validateNonEmpty(String value, String field) {
  if (value.isEmpty) throw FormatException('$field must not be empty.');
  return value;
}

bool _requiredBool(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! bool) throw FormatException('Invalid $key.');
  return value;
}

int _requiredPositiveInt(Map<Object?, Object?> map, String key) {
  final value = _requiredNonNegativeInt(map, key);
  if (value == 0) throw FormatException('$key must be positive.');
  return value;
}

int _requiredNonNegativeInt(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key.');
  return value;
}
