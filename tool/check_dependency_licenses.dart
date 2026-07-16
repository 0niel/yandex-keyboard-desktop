import 'dart:convert';
import 'dart:io';

enum DependencyLicenseFamily {
  mit('MIT'),
  bsd('BSD'),
  apache2('Apache-2.0'),
  isc('ISC'),
  mpl2('MPL-2.0'),
  zlib('Zlib'),
  flutterEngineAggregate('Flutter-engine aggregate');

  const DependencyLicenseFamily(this.label);
  final String label;
}

final class DependencyLicenseRecord {
  const DependencyLicenseRecord({
    required this.package,
    required this.family,
  });

  final String package;
  final DependencyLicenseFamily family;
}

final class DependencyLicenseIssue {
  const DependencyLicenseIssue(this.package, this.message);
  final String package;
  final String message;
}

final class DependencyLicenseAudit {
  const DependencyLicenseAudit({required this.records, required this.issues});
  final List<DependencyLicenseRecord> records;
  final List<DependencyLicenseIssue> issues;
}

DependencyLicenseAudit auditPackageLicenses(File packageConfig) {
  final decoded = jsonDecode(packageConfig.readAsStringSync());
  if (decoded is! Map<String, dynamic> || decoded['packages'] is! List) {
    return const DependencyLicenseAudit(
      records: [],
      issues: [DependencyLicenseIssue('package_config', 'invalid schema')],
    );
  }

  final records = <DependencyLicenseRecord>[];
  final issues = <DependencyLicenseIssue>[];
  for (final value in decoded['packages'] as List) {
    if (value is! Map<String, dynamic> ||
        value['name'] is! String ||
        value['rootUri'] is! String) {
      issues.add(const DependencyLicenseIssue(
        'package_config',
        'contains a malformed package entry',
      ));
      continue;
    }
    final package = value['name'] as String;
    final rootUri = packageConfig.absolute.uri.resolve(
      value['rootUri'] as String,
    );
    if (rootUri.scheme != 'file') {
      issues.add(DependencyLicenseIssue(package, 'root URI is not local'));
      continue;
    }
    final licenses = _findLicenseFiles(
      package: package,
      packageRoot: Directory.fromUri(rootUri),
    );
    if (licenses.isEmpty) {
      issues.add(DependencyLicenseIssue(package, 'license file is missing'));
      continue;
    }
    var compatible = true;
    for (final license in licenses) {
      final family = classifyDependencyLicense(
        package: package,
        text: license.readAsStringSync(),
      );
      if (family == null) {
        compatible = false;
        issues.add(DependencyLicenseIssue(
          package,
          'license is unknown or incompatible (${license.path})',
        ));
      } else {
        records.add(DependencyLicenseRecord(
          package: package,
          family: family,
        ));
      }
    }
    if (!compatible) {
      records.removeWhere((record) => record.package == package);
    }
  }
  records.sort((left, right) => left.package.compareTo(right.package));
  issues.sort((left, right) => left.package.compareTo(right.package));
  return DependencyLicenseAudit(records: records, issues: issues);
}

DependencyLicenseFamily? classifyDependencyLicense({
  required String package,
  required String text,
}) {
  if (package == 'sky_engine') {
    return DependencyLicenseFamily.flutterEngineAggregate;
  }
  final normalized = text.toLowerCase();
  if (normalized.contains('gnu affero general public license') ||
      normalized.contains('gnu lesser general public license') ||
      normalized.contains('gnu general public license') ||
      normalized.contains('server side public license') ||
      normalized.contains('commons clause')) {
    return null;
  }
  if (normalized.contains('permission is hereby granted, free of charge') ||
      normalized.contains('the mit license')) {
    return DependencyLicenseFamily.mit;
  }
  if (normalized.contains('apache license') &&
      normalized.contains('version 2.0')) {
    return DependencyLicenseFamily.apache2;
  }
  if (normalized.contains(
    'redistribution and use in source and binary forms',
  )) {
    return DependencyLicenseFamily.bsd;
  }
  if (normalized.contains('isc license')) {
    return DependencyLicenseFamily.isc;
  }
  if (normalized.contains('mozilla public license') &&
      normalized.contains('version 2.0')) {
    return DependencyLicenseFamily.mpl2;
  }
  if (normalized.contains('zlib license')) {
    return DependencyLicenseFamily.zlib;
  }
  return null;
}

List<File> _findLicenseFiles({
  required String package,
  required Directory packageRoot,
}) {
  final direct = _licenseFilesIn(packageRoot);
  if (direct.isNotEmpty) return direct;

  const flutterSdkPackages = {
    'flutter_driver',
    'flutter_localizations',
    'flutter_test',
    'flutter_web_plugins',
    'fuchsia_remote_debug_protocol',
    'integration_test',
  };
  if (!flutterSdkPackages.contains(package)) return const [];
  final packagesDirectory = packageRoot.parent;
  final flutterRoot = packagesDirectory.parent;
  final expectedRoot = Directory('${packagesDirectory.path}/$package');
  final flutterLauncher = Platform.isWindows
      ? File('${flutterRoot.path}/bin/flutter.bat')
      : File('${flutterRoot.path}/bin/flutter');
  if (!FileSystemEntity.identicalSync(expectedRoot.path, packageRoot.path) ||
      !flutterLauncher.existsSync()) {
    return const [];
  }
  return _licenseFilesIn(flutterRoot);
}

List<File> _licenseFilesIn(Directory directory) {
  if (!directory.existsSync()) return const [];
  final candidates =
      directory.listSync(followLinks: false).whereType<File>().where((file) {
    final name = file.uri.pathSegments.last.toLowerCase();
    return RegExp(r'^(license|licence|copying)(\..*)?$').hasMatch(name);
  }).toList()
        ..sort((left, right) => left.path.compareTo(right.path));
  return candidates;
}

void main(List<String> arguments) {
  final config = File(
    arguments.isEmpty ? '.dart_tool/package_config.json' : arguments.single,
  );
  if (!config.existsSync()) {
    stderr.writeln('Package config does not exist: ${config.path}');
    exitCode = 64;
    return;
  }
  final audit = auditPackageLicenses(config);
  for (final record in audit.records) {
    stdout.writeln('${record.package}: ${record.family.label}');
  }
  for (final issue in audit.issues) {
    stderr.writeln('${issue.package}: ${issue.message}');
  }
  stdout.writeln(
    'Audited ${audit.records.length + audit.issues.length} package licenses; '
    '${audit.issues.length} issue(s).',
  );
  if (audit.issues.isNotEmpty) exitCode = 1;
}
