import 'dart:convert';
import 'dart:io';

final class PubSecurityIssue {
  const PubSecurityIssue(this.package, this.reason);
  final String package;
  final String reason;
}

List<PubSecurityIssue> auditPubOutdatedReport(Object? report) {
  if (report is! Map<String, dynamic> || report['packages'] is! List) {
    return const [PubSecurityIssue('pub', 'invalid outdated-report schema')];
  }
  final issues = <PubSecurityIssue>[];
  for (final value in report['packages'] as List) {
    if (value is! Map<String, dynamic> || value['package'] is! String) {
      issues.add(const PubSecurityIssue(
        'pub',
        'malformed package entry',
      ));
      continue;
    }
    if (value['current'] == null) continue;
    final package = value['package'] as String;
    if (value['isCurrentAffectedByAdvisory'] == true) {
      issues.add(PubSecurityIssue(package, 'affected by a security advisory'));
    }
    if (value['isCurrentRetracted'] == true) {
      issues.add(PubSecurityIssue(package, 'resolved version is retracted'));
    }
    if (value['isDiscontinued'] == true) {
      issues.add(PubSecurityIssue(package, 'package is discontinued'));
    }
  }
  return issues;
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/check_pub_security.dart <pub-outdated.json>',
    );
    exitCode = 64;
    return;
  }
  final contents = arguments.single == '-'
      ? await stdin.transform(utf8.decoder).join()
      : File(arguments.single).readAsStringSync();
  final report = jsonDecode(contents);
  final issues = auditPubOutdatedReport(report);
  if (issues.isEmpty) {
    stdout.writeln('No resolved Pub advisory, retraction, or discontinuation.');
    return;
  }
  for (final issue in issues) {
    stderr.writeln('${issue.package}: ${issue.reason}');
  }
  exitCode = 1;
}
