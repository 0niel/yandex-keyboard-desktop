import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_pub_security.dart';

void main() {
  test('accepts resolved packages without supply-chain warnings', () {
    final issues = auditPubOutdatedReport({
      'packages': [
        {
          'package': 'safe',
          'current': {'version': '1.0.0'},
          'isCurrentAffectedByAdvisory': false,
          'isCurrentRetracted': false,
          'isDiscontinued': false,
        },
        {
          'package': 'not_resolved',
          'current': null,
          'isCurrentAffectedByAdvisory': true,
        },
      ],
    });

    expect(issues, isEmpty);
  });

  test('rejects advisories, retractions, and discontinued packages', () {
    final issues = auditPubOutdatedReport({
      'packages': [
        {
          'package': 'advisory',
          'current': {'version': '1.0.0'},
          'isCurrentAffectedByAdvisory': true,
        },
        {
          'package': 'retracted',
          'current': {'version': '1.0.0'},
          'isCurrentRetracted': true,
        },
        {
          'package': 'discontinued',
          'current': {'version': '1.0.0'},
          'isDiscontinued': true,
        },
      ],
    });

    expect(issues, hasLength(3));
    expect(
      issues.map((issue) => issue.package),
      ['advisory', 'retracted', 'discontinued'],
    );
  });

  test('fails closed on malformed reports', () {
    expect(auditPubOutdatedReport(null), hasLength(1));
    expect(
      auditPubOutdatedReport({
        'packages': [
          {'current': {}},
        ],
      }),
      hasLength(1),
    );
  });
}
