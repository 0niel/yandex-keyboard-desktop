import 'package:equatable/equatable.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';

enum SettingsStage { loading, ready, saving, failure }

final class ProfileKeyBindingIssue extends Equatable {
  const ProfileKeyBindingIssue({
    required this.profileId,
    required this.issue,
  });

  final String profileId;
  final KeyBindingIssue issue;

  @override
  List<Object?> get props => [profileId, issue];
}

final class SettingsState extends Equatable {
  const SettingsState({
    this.stage = SettingsStage.loading,
    this.authoritative,
    this.draft,
    this.issues = const [],
    this.errorCode,
    this.conflictedShortcuts = const [],
  });

  final SettingsStage stage;
  final AppSettings? authoritative;
  final AppSettings? draft;
  final List<ProfileKeyBindingIssue> issues;
  final String? errorCode;

  final List<ShortcutAction> conflictedShortcuts;

  bool get isDirty => authoritative != null && draft != authoritative;
  bool get hasBlockingIssues => issues.any(
        (entry) => entry.issue.kind != KeyBindingIssueKind.unsupportedPlatform,
      );

  @override
  List<Object?> get props => [
        stage,
        authoritative,
        draft,
        issues,
        errorCode,
        conflictedShortcuts,
      ];
}
