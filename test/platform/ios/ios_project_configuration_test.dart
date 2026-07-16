import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final project =
      File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
  final extensionInfo =
      File('ios/KeyboardExtension/Info.plist').readAsStringSync();
  final extensionEntitlements =
      File('ios/KeyboardExtension/KeyboardExtension.entitlements')
          .readAsStringSync();
  final runnerEntitlements =
      File('ios/Runner/Runner.entitlements').readAsStringSync();
  final extensionPrivacy =
      File('ios/KeyboardExtension/PrivacyInfo.xcprivacy').readAsStringSync();
  final runnerPrivacy =
      File('ios/Runner/PrivacyInfo.xcprivacy').readAsStringSync();
  final transformationService = File(
    'ios/KeyboardExtension/KeyboardTransformationService.swift',
  ).readAsStringSync();
  final extensionBuildConfiguration =
      File('ios/KeyboardExtension/Build.xcconfig').readAsStringSync();
  final runnerDebugConfiguration =
      File('ios/Flutter/Debug.xcconfig').readAsStringSync();
  final runnerProfileConfiguration =
      File('ios/Flutter/Profile.xcconfig').readAsStringSync();
  final runnerReleaseConfiguration =
      File('ios/Flutter/Release.xcconfig').readAsStringSync();
  final flutterMetadata = File('.metadata').readAsStringSync();
  final podLock = File('ios/Podfile.lock').readAsStringSync();

  test('host embeds a version-aligned, extension-safe keyboard target', () {
    expect(
        project, contains('KeyboardExtension.appex in Embed App Extensions'));
    expect(project, contains('APPLICATION_EXTENSION_API_ONLY = YES;'));
    expect(
      RegExp(
        r'baseConfigurationReference = A1100000000000000000000F /\* Build\.xcconfig \*/;',
      ).allMatches(project),
      hasLength(3),
      reason: 'every extension configuration must remain isolated from Runner',
    );
    for (final forbidden in [
      'Generated.xcconfig',
      'Pods-Runner',
      'FLUTTER_ROOT',
      'FRAMEWORK_SEARCH_PATHS',
      'OTHER_LDFLAGS',
    ]) {
      expect(
        extensionBuildConfiguration,
        isNot(contains(forbidden)),
        reason: 'the native extension must not inherit Flutter/Runner linkage',
      );
    }
    for (final entry in {
      runnerDebugConfiguration: 'Pods-Runner.debug.xcconfig',
      runnerProfileConfiguration: 'Pods-Runner.profile.xcconfig',
      runnerReleaseConfiguration: 'Pods-Runner.release.xcconfig',
    }.entries) {
      expect(entry.key, contains(entry.value));
      expect(entry.key, contains('Generated.xcconfig'));
    }
    expect(
      project,
      contains(
        'baseConfigurationReference = A11000000000000000000010 '
        '/* Profile.xcconfig */;',
      ),
    );
    expect(flutterMetadata, contains('- platform: ios'));
    expect(podLock, contains('COCOAPODS: 1.16.2'));
    expect(podLock, contains('package_info_plus (0.4.5)'));
    expect(podLock, contains('path_provider_foundation (0.0.1)'));
    final extensionTarget = RegExp(
      r'A14000000000000000000001 /\* KeyboardExtension \*/ = \{([\s\S]*?)\n\t\t\};',
    ).firstMatch(project);
    expect(extensionTarget, isNotNull);
    expect(extensionTarget!.group(1), isNot(contains('[CP]')));
    expect(extensionTarget.group(1), isNot(contains('Pods')));
    final packageVersion = RegExp(
      r'^version:\s*([^+\s]+)\+([^\s]+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync());
    expect(packageVersion, isNotNull);
    expect(
      extensionBuildConfiguration,
      contains('FLUTTER_BUILD_NAME = ${packageVersion!.group(1)}'),
    );
    expect(
      extensionBuildConfiguration,
      contains('FLUTTER_BUILD_NUMBER = ${packageVersion.group(2)}'),
    );
    expect(
      RegExp(r'MARKETING_VERSION = "\$\(FLUTTER_BUILD_NAME\)";')
          .allMatches(project),
      hasLength(6),
    );
    expect(
      RegExp(r'CURRENT_PROJECT_VERSION = "\$\(FLUTTER_BUILD_NUMBER\)";')
          .allMatches(project),
      hasLength(6),
    );
    for (final source in [
      'KeyboardSettings.swift',
      'KeyboardTransaction.swift',
      'KeyboardTransformationService.swift',
      'KeyboardLayout.swift',
    ]) {
      expect(
        RegExp('${RegExp.escape(source)} in Sources')
            .allMatches(project)
            .length,
        greaterThanOrEqualTo(4),
        reason: '$source must compile in the extension and native-test targets',
      );
    }
  });

  test('keyboard capabilities and shared container declarations agree', () {
    expect(_booleanValue(extensionInfo, 'IsASCIICapable'), isTrue);
    expect(_booleanValue(extensionInfo, 'RequestsOpenAccess'), isTrue);
    const appGroup = 'group.io.github.oniel.yandexKeyboardDesktop';
    expect(extensionEntitlements, contains('<string>$appGroup</string>'));
    expect(runnerEntitlements, contains('<string>$appGroup</string>'));
    expect(
        extensionPrivacy, contains('NSPrivacyAccessedAPICategoryUserDefaults'));
    expect(extensionPrivacy, contains('<string>1C8F.1</string>'));
    for (final manifest in [extensionPrivacy, runnerPrivacy]) {
      expect(manifest,
          isNot(contains('NSPrivacyCollectedDataTypeOtherUserContent')));
      expect(manifest, contains('<key>NSPrivacyCollectedDataTypes</key>'));
      expect(manifest, contains('<key>NSPrivacyTracking</key>'));
      expect(manifest, contains('<false/>'));
    }
    expect(
      RegExp(r'YKD_TRANSFORMATION_SERVICE_BASE_URL = "";').allMatches(project),
      hasLength(3),
    );
    expect(
      RegExp(r'YKD_TRANSFORMATION_SERVICE_PRIVACY_REVIEWED = NO;')
          .allMatches(project),
      hasLength(3),
    );
    expect(
      extensionInfo,
      contains(r'$(YKD_TRANSFORMATION_SERVICE_PRIVACY_REVIEWED)'),
    );
    expect(transformationService, isNot(contains('keyboard.yandex.net')));
  });

  test('every native keyboard string ships in English and Russian', () {
    final catalog = jsonDecode(
      File('ios/KeyboardExtension/Localizable.xcstrings').readAsStringSync(),
    ) as Map<String, dynamic>;
    final strings = catalog['strings'] as Map<String, dynamic>;
    expect(strings.keys, containsAll(['letters', 'numbers', 'symbols']));
    for (final entry in strings.entries) {
      final localizations = (entry.value
          as Map<String, dynamic>)['localizations'] as Map<String, dynamic>;
      expect(
        localizations.keys,
        containsAll(['en', 'ru']),
        reason: '${entry.key} must be localized for every shipped language',
      );
    }
  });
}

bool _booleanValue(String plist, String key) {
  final match = RegExp(
    '<key>${RegExp.escape(key)}</key>\\s*<(true|false)/>',
  ).firstMatch(plist);
  if (match == null) throw StateError('Missing Boolean plist key: $key');
  return match.group(1) == 'true';
}
