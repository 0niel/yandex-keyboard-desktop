import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_dependency_licenses.dart';

void main() {
  test('audits direct and explicitly trusted Flutter SDK licenses', () {
    final root = Directory.systemTemp.createTempSync('ykd-license-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final direct = Directory('${root.path}/direct')..createSync();
    File('${direct.path}/LICENSE').writeAsStringSync(
      'MIT License\nPermission is hereby granted, free of charge',
    );
    const sdkPackageNames = [
      'flutter_driver',
      'flutter_localizations',
      'fuchsia_remote_debug_protocol',
      'integration_test',
    ];
    final sdkPackages = [
      for (final name in sdkPackageNames)
        Directory('${root.path}/sdk/packages/$name')
          ..createSync(recursive: true),
    ];
    File('${root.path}/sdk/bin/flutter${Platform.isWindows ? '.bat' : ''}')
      ..createSync(recursive: true)
      ..writeAsStringSync('flutter launcher');
    File('${root.path}/sdk/LICENSE').writeAsStringSync(
      'Redistribution and use in source and binary forms are permitted.',
    );
    final config = File('${root.path}/package_config.json')
      ..writeAsStringSync(jsonEncode({
        'packages': [
          {'name': 'direct', 'rootUri': direct.uri.toString()},
          for (var index = 0; index < sdkPackageNames.length; index++)
            {
              'name': sdkPackageNames[index],
              'rootUri': sdkPackages[index].uri.toString(),
            },
        ],
      }));

    final audit = auditPackageLicenses(config);

    expect(audit.issues, isEmpty);
    expect(
      audit.records.map((record) => record.family),
      [
        DependencyLicenseFamily.mit,
        ...List.filled(sdkPackageNames.length, DependencyLicenseFamily.bsd),
      ],
    );
  });

  test('does not inherit an unrelated parent license', () {
    final root = Directory.systemTemp.createTempSync('ykd-license-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final package = Directory('${root.path}/parent/package')
      ..createSync(recursive: true);
    File('${root.path}/parent/LICENSE').writeAsStringSync(
      'MIT License\nPermission is hereby granted, free of charge',
    );
    final config = File('${root.path}/package_config.json')
      ..writeAsStringSync(jsonEncode({
        'packages': [
          {'name': 'unrelated', 'rootUri': package.uri.toString()},
        ],
      }));

    final audit = auditPackageLicenses(config);

    expect(audit.records, isEmpty);
    expect(audit.issues.single.message, 'license file is missing');
  });

  test('rejects a package when any declared license file is incompatible', () {
    final root = Directory.systemTemp.createTempSync('ykd-license-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final package = Directory('${root.path}/dual')..createSync();
    File('${package.path}/LICENSE').writeAsStringSync(
      'MIT License\nPermission is hereby granted, free of charge',
    );
    File('${package.path}/COPYING').writeAsStringSync(
      'GNU GENERAL PUBLIC LICENSE Version 3',
    );
    final config = File('${root.path}/package_config.json')
      ..writeAsStringSync(jsonEncode({
        'packages': [
          {'name': 'dual', 'rootUri': package.uri.toString()},
        ],
      }));

    final audit = auditPackageLicenses(config);

    expect(audit.records, isEmpty);
    expect(audit.issues.single.message, contains('unknown or incompatible'));
  });

  test('rejects strong-copyleft, unknown, missing, and malformed entries', () {
    final root = Directory.systemTemp.createTempSync('ykd-license-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final gpl = Directory('${root.path}/gpl')..createSync();
    File('${gpl.path}/COPYING').writeAsStringSync(
      'GNU GENERAL PUBLIC LICENSE Version 3',
    );
    final unknown = Directory('${root.path}/unknown')..createSync();
    File('${unknown.path}/LICENSE').writeAsStringSync('All rights reserved.');
    final missing = Directory('${root.path}/missing')..createSync();
    final config = File('${root.path}/package_config.json')
      ..writeAsStringSync(jsonEncode({
        'packages': [
          {'name': 'gpl', 'rootUri': gpl.uri.toString()},
          {'name': 'missing', 'rootUri': missing.uri.toString()},
          {'name': 'unknown', 'rootUri': unknown.uri.toString()},
          {'name': 'malformed'},
        ],
      }));

    final audit = auditPackageLicenses(config);

    expect(audit.records, isEmpty);
    expect(audit.issues, hasLength(4));
    expect(
      audit.issues.map((issue) => issue.message),
      containsAll([
        contains('unknown or incompatible'),
        contains('missing'),
        contains('malformed'),
      ]),
    );
  });

  test('recognizes the Flutter engine aggregate by package identity', () {
    expect(
      classifyDependencyLicense(package: 'sky_engine', text: 'not SPDX'),
      DependencyLicenseFamily.flutterEngineAggregate,
    );
  });
}
