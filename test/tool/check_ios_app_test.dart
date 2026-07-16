import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts the expected unsigned offline iOS archive', () async {
    final fixture = await _fixture();
    addTearDown(() => fixture.parent.delete(recursive: true));

    final result = await _audit(fixture);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('signed=false'));
    expect(result.stdout, contains('sha256='));
  });

  test('rejects a keyboard extension that embeds Flutter', () async {
    final fixture = await _fixture(extensionEmbedsFlutter: true);
    addTearDown(() => fixture.parent.delete(recursive: true));

    final result = await _audit(fixture);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('embeds a dynamic framework'));
  });

  test('rejects a version-mismatched keyboard extension', () async {
    final fixture = await _fixture(extensionBuild: '2');
    addTearDown(() => fixture.parent.delete(recursive: true));

    final result = await _audit(fixture);

    expect(result.exitCode, 1);
    expect(result.stderr, contains("CFBundleVersion is '2'; expected '1'"));
  });

  test('rejects an enabled network endpoint in the offline artifact', () async {
    final fixture = await _fixture(networkEnabled: true);
    addTearDown(() => fixture.parent.delete(recursive: true));

    final result = await _audit(fixture);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('unexpectedly configures'));
    expect(result.stderr, contains('unexpectedly enables'));
  });

  test('rejects private configuration payloads', () async {
    final fixture = await _fixture(includeSecrets: true);
    addTearDown(() => fixture.parent.delete(recursive: true));

    final result = await _audit(fixture);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('forbidden private-data path'));
  });

  test('rejects a signature in the unsigned artifact', () async {
    final fixture = await _fixture(includeSignature: true);
    addTearDown(() => fixture.parent.delete(recursive: true));

    final result = await _audit(fixture);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('signature leaked into unsigned artifact'));
  });

  test('allows a simulator signature only when explicitly requested', () async {
    final fixture = await _fixture(includeSignature: true);
    addTearDown(() => fixture.parent.delete(recursive: true));

    final result = await _audit(fixture, allowSignature: true);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('signed=allowed'));
  });

  test('rejects an archive with an excessive entry count', () async {
    final fixture = await _fixture(excessEntries: true);
    addTearDown(() => fixture.parent.delete(recursive: true));

    final result = await _audit(fixture);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('archive contains too many entries'));
  });
}

Future<ProcessResult> _audit(
  File fixture, {
  bool allowSignature = false,
}) =>
    Process.run(
      'python',
      [
        'tool/check_ios_app.py',
        if (allowSignature) '--allow-signature',
        fixture.path,
      ],
      workingDirectory: Directory.current.path,
    );

Future<File> _fixture({
  bool extensionEmbedsFlutter = false,
  String extensionBuild = '1',
  bool networkEnabled = false,
  bool includeSecrets = false,
  bool includeSignature = false,
  bool excessEntries = false,
}) async {
  final directory = await Directory.systemTemp.createTemp('ykd-ios-audit-');
  final archive = File('${directory.path}/Runner-offline-unsigned.zip');
  const createArchive = r'''
import plistlib, sys, zipfile

path = sys.argv[1]
flutter = sys.argv[2] == "1"
extension_build = sys.argv[3]
network = sys.argv[4] == "1"
secrets = sys.argv[5] == "1"
signature = sys.argv[6] == "1"
excess_entries = sys.argv[7] == "1"

host_info = {
  "CFBundlePackageType": "APPL",
  "CFBundleIdentifier": "io.github.oniel.yandexKeyboardDesktop",
  "CFBundleShortVersionString": "1.0.0",
  "CFBundleVersion": "1",
  "CFBundleExecutable": "Runner",
}
extension_info = {
  "CFBundlePackageType": "XPC!",
  "CFBundleIdentifier": "io.github.oniel.yandexKeyboardDesktop.Keyboard",
  "CFBundleShortVersionString": "1.0.0",
  "CFBundleVersion": extension_build,
  "CFBundleExecutable": "KeyboardExtension",
  "YKDTransformationServiceBaseURL": "https://example.invalid/" if network else "",
  "YKDTransformationServicePrivacyReviewed": "YES" if network else "NO",
  "NSExtension": {
    "NSExtensionPointIdentifier": "com.apple.keyboard-service",
    "NSExtensionAttributes": {
      "IsASCIICapable": True,
      "RequestsOpenAccess": True,
    },
  },
}
privacy = {
  "NSPrivacyTracking": False,
  "NSPrivacyCollectedDataTypes": [],
  "NSPrivacyAccessedAPITypes": [{
    "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
    "NSPrivacyAccessedAPITypeReasons": ["1C8F.1"],
  }],
}

entries = {
  "Runner.app/Info.plist": plistlib.dumps(host_info),
  "Runner.app/Runner": b"fixture",
  "Runner.app/PrivacyInfo.xcprivacy": plistlib.dumps(privacy),
  "Runner.app/Frameworks/App.framework/flutter_assets/NOTICES.Z": b"notices",
  "Runner.app/Frameworks/App.framework/flutter_assets/assets/brand/symbol.svg": b"<svg/>",
  "Runner.app/Frameworks/App.framework/flutter_assets/assets/brand/wordmark.svg": b"<svg/>",
  "Runner.app/PlugIns/KeyboardExtension.appex/Info.plist": plistlib.dumps(extension_info),
  "Runner.app/PlugIns/KeyboardExtension.appex/KeyboardExtension": b"fixture",
  "Runner.app/PlugIns/KeyboardExtension.appex/PrivacyInfo.xcprivacy": plistlib.dumps(privacy),
}
if flutter:
  entries["Runner.app/PlugIns/KeyboardExtension.appex/Frameworks/Flutter.framework/Flutter"] = b"fixture"
if secrets:
  entries["Runner.app/Frameworks/App.framework/flutter_assets/secrets/token.txt"] = b"private"
if signature:
  entries["Runner.app/_CodeSignature/CodeResources"] = b"signed"

with zipfile.ZipFile(path, "w") as archive:
  for name, value in entries.items():
    info = zipfile.ZipInfo(name)
    executable = name.endswith(("/Runner", "/KeyboardExtension"))
    info.external_attr = (0o755 if executable else 0o644) << 16
    archive.writestr(info, value)
  if excess_entries:
    for index in range(10001):
      archive.writestr(f"Runner.app/padding/{index}", b"")
''';
  final result = await Process.run('python', [
    '-c',
    createArchive,
    archive.path,
    extensionEmbedsFlutter ? '1' : '0',
    extensionBuild,
    networkEnabled ? '1' : '0',
    includeSecrets ? '1' : '0',
    includeSignature ? '1' : '0',
    excessEntries ? '1' : '0',
  ]);
  if (result.exitCode != 0) {
    throw StateError('Could not create iOS fixture: ${result.stderr}');
  }
  return archive;
}
