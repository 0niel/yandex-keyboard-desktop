import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';

enum PrivacyActivityStage { initial, loading, ready, busy, failure }

final class PrivacyActivityState extends Equatable {
  const PrivacyActivityState({
    this.stage = PrivacyActivityStage.initial,
    this.snapshot,
    this.lastExportPath,
    this.errorCode,
  });

  final PrivacyActivityStage stage;
  final PrivacyActivitySnapshot? snapshot;
  final String? lastExportPath;
  final String? errorCode;

  int get historyCount => snapshot?.history.length ?? 0;
  int get diagnosticsCount => snapshot?.diagnostics.length ?? 0;
  int get managedExportCount => snapshot?.managedExportCount ?? 0;
  bool get managedExportsKnown => snapshot?.managedExportsKnown ?? false;

  @override
  List<Object?> get props => [stage, snapshot, lastExportPath, errorCode];
}

final class PrivacyActivityController extends Cubit<PrivacyActivityState>
    implements PrivacyActivityRecorder {
  PrivacyActivityController({required PrivacyActivityRepository repository})
      : _repository = repository,
        super(const PrivacyActivityState());

  final PrivacyActivityRepository _repository;
  int _foregroundEpoch = 0;

  Future<void> initialize() async {
    emit(const PrivacyActivityState(stage: PrivacyActivityStage.loading));
    try {
      final snapshot = await _repository.load();
      emit(PrivacyActivityState(
        stage: PrivacyActivityStage.ready,
        snapshot: snapshot,
      ));
    } catch (_) {
      emit(const PrivacyActivityState(
        stage: PrivacyActivityStage.failure,
        errorCode: 'privacy_data_load_failed',
      ));
    }
  }

  @override
  Future<void> record(
    PrivacyActivityEvent event, {
    required PrivacyConsent consent,
  }) async {
    if (!consent.anyEnabled) return;
    final epoch = _foregroundEpoch;
    try {
      final snapshot = await _repository.record(
        event,
        consent: consent,
      );
      if (!_canPublishRecord(epoch)) return;
      emit(PrivacyActivityState(
        stage: PrivacyActivityStage.ready,
        snapshot: snapshot,
        lastExportPath: _retainedExportPath(snapshot, state.lastExportPath),
      ));
    } catch (_) {
      if (!_canPublishRecord(epoch)) return;
      final snapshot = await _reloadAfterFailure();
      if (!_canPublishRecord(epoch)) return;
      emit(PrivacyActivityState(
        stage: PrivacyActivityStage.ready,
        snapshot: snapshot,
        lastExportPath: _retainedExportPath(snapshot, state.lastExportPath),
        errorCode: 'privacy_data_write_failed',
      ));
    }
  }

  Future<void> clearHistory() => _mutate(
        _repository.clearHistory,
        failureCode: 'privacy_history_clear_failed',
      );

  Future<void> clearDiagnostics() => _mutate(
        _repository.clearDiagnostics,
        failureCode: 'privacy_diagnostics_clear_failed',
        clearExportPath: true,
      );

  Future<void> exportDiagnostics() async {
    if (state.stage == PrivacyActivityStage.busy) return;
    final epoch = ++_foregroundEpoch;
    emit(PrivacyActivityState(
      stage: PrivacyActivityStage.busy,
      snapshot: state.snapshot,
      lastExportPath: state.lastExportPath,
    ));
    try {
      final path = await _repository.exportDiagnostics();
      final snapshot = await _repository.load();
      if (epoch != _foregroundEpoch) return;
      emit(PrivacyActivityState(
        stage: PrivacyActivityStage.ready,
        snapshot: snapshot,
        lastExportPath: path,
      ));
    } catch (_) {
      if (epoch != _foregroundEpoch) return;
      final snapshot = await _reloadAfterFailure();
      if (epoch != _foregroundEpoch) return;
      emit(PrivacyActivityState(
        stage: PrivacyActivityStage.ready,
        snapshot: snapshot,
        lastExportPath: _retainedExportPath(snapshot, state.lastExportPath),
        errorCode: 'privacy_diagnostics_export_failed',
      ));
    }
  }

  Future<void> _mutate(
    Future<PrivacyActivitySnapshot> Function() operation, {
    required String failureCode,
    bool clearExportPath = false,
  }) async {
    if (state.stage == PrivacyActivityStage.busy) return;
    final epoch = ++_foregroundEpoch;
    emit(PrivacyActivityState(
      stage: PrivacyActivityStage.busy,
      snapshot: state.snapshot,
      lastExportPath: state.lastExportPath,
    ));
    try {
      final snapshot = await operation();
      if (epoch != _foregroundEpoch) return;
      emit(PrivacyActivityState(
        stage: PrivacyActivityStage.ready,
        snapshot: snapshot,
        lastExportPath: clearExportPath
            ? null
            : _retainedExportPath(snapshot, state.lastExportPath),
      ));
    } catch (_) {
      if (epoch != _foregroundEpoch) return;
      final snapshot = await _reloadAfterFailure();
      if (epoch != _foregroundEpoch) return;
      emit(PrivacyActivityState(
        stage: PrivacyActivityStage.ready,
        snapshot: snapshot,
        lastExportPath: clearExportPath
            ? null
            : _retainedExportPath(snapshot, state.lastExportPath),
        errorCode: failureCode,
      ));
    }
  }

  bool _canPublishRecord(int epoch) =>
      epoch == _foregroundEpoch && state.stage != PrivacyActivityStage.busy;

  Future<PrivacyActivitySnapshot?> _reloadAfterFailure() async {
    try {
      return await _repository.load();
    } catch (_) {
      return state.snapshot;
    }
  }

  String? _retainedExportPath(
    PrivacyActivitySnapshot? snapshot,
    String? currentPath,
  ) {
    if (snapshot != null &&
        snapshot.managedExportsKnown &&
        currentPath != null &&
        !snapshot.managedExportPaths.contains(currentPath)) {
      return null;
    }
    return currentPath;
  }
}
