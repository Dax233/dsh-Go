import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_repository.dart' show WorkshopPublication;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('unknown kind is retained but cannot be sent to a pet installer', () {
    final catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [workshopEntryJson(metadata: {
      ...workshopMeta(kind: 'wallpaper'), 'size': 40 * 1024 * 1024, 'license': 'LicenseRef-Future-Kind',
    })]));
    expect(catalog.entries.single.metadata.kind, 'wallpaper');
    expect(catalog.entries.single.metadata.size, 40 * 1024 * 1024);
    expect(catalog.unavailable(catalog.entries.single, '1.0.15'), 'workshop_unsupported_kind');
    expect(() => WorkshopMetadata.fromJson(catalog.entries.single.metadata.toJson()), workshopError('workshop_bad_metadata'));
    expect(() => WorkshopMetadata.fromJson({...workshopMeta(), 'size': 40 * 1024 * 1024}, submission: false), workshopError('workshop_bad_catalog'));
  });

  test('minApp, companion switch and withdrawals have stable independent gates', () {
    final entry = workshopEntryJson(metadata: workshopMeta(kind: 'companion', minApp: '1.1.0'));
    var catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [entry]));
    expect(catalog.unavailable(catalog.entries.single, '1.0.15+123'), 'workshop_min_app');
    expect(catalog.unavailable(catalog.entries.single, '1.1.0'), isNull);
    catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [entry], companion: false));
    expect(catalog.unavailable(catalog.entries.single, '1.1.0'), 'workshop_companion_disabled');
    catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [{...entry, 'blockedVersions': ['1.0.0']}]));
    expect(catalog.blocked('companion', 'cat', '1.0.0'), isTrue);
    expect(catalog.unavailable(catalog.entries.single, '1.1.0'), 'workshop_version_withdrawn');
  });

  test('URLs are exact content-addressed paths, not remote links or alternate hashes', () {
    for (final url in ['https://elsewhere.example/file.zip', '//elsewhere.example/file.zip', '/market/workshop/pet/cat/1.0.0/bad.zip']) {
      expect(() => WorkshopEntry.fromJson({...workshopEntryJson(), 'url': url}), throwsA(isA<WorkshopException>()));
    }
  });

  test('public metadata and publication reject raw whitespace in source URLs', () {
    for (final source in ['https://source.example/path value', 'https://source.example/path\u00a0value']) {
      final value = {...workshopMeta(), 'source': source};
      expect(() => WorkshopMetadata.fromJson(value), workshopError('workshop_bad_metadata'));
      expect(() => WorkshopPublication(value), workshopError('workshop_bad_metadata'));
    }
  });

  test('encoded source URLs keep exactly the same bytes through public metadata', () {
    for (final source in ['https://source.example/path%20value', 'https://source.example/path%C2%A0value']) {
      final value = {...workshopMeta(), 'source': source};
      final metadata = WorkshopMetadata.fromJson(value), publication = WorkshopPublication(value);
      expect(metadata.source, source);
      expect(metadata.toJson()['source'], source);
      expect(publication.source, source);
      expect(publication.withArchive('a' * 64, 17).toJson()['source'], source);
    }
  });

  test('duplicate identities, malformed timestamps and source credentials are rejected', () {
    expect(() => WorkshopCatalog.fromJson(workshopCatalogJson(entries: [workshopEntryJson(), workshopEntryJson()])), throwsA(isA<WorkshopException>()));
    expect(() => WorkshopCatalog.fromJson(workshopCatalogJson(at: '2026-02-31T00:00:00.000Z')), throwsA(isA<WorkshopException>()));
    expect(() => WorkshopMetadata.fromJson({...workshopMeta(), 'source': 'https://user:secret@source.example'}), throwsA(isA<WorkshopException>()));
  });

  test('SemVer ordering is exact even above int64 and build metadata is not a release', () {
    const versions = ['1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-alpha.beta', '1.0.0-beta', '1.0.0-beta.2', '1.0.0-beta.11', '1.0.0-rc.1', '1.0.0', '2.0.0'];
    for (var i = 1; i < versions.length; i++) {
      expect(WorkshopVersion.tryParse(versions[i])!.compareTo(WorkshopVersion.tryParse(versions[i - 1])!), greaterThan(0));
    }
    expect(WorkshopVersion.tryParse('999999999999999999999.0.0')!.compareTo(WorkshopVersion.tryParse('1000000000000000000000.0.0')!), lessThan(0));
    for (final bad in ['1.0', '01.0.0', '1.0.0+1', '1.0.0-01', '1.0.0-a..b']) { expect(WorkshopVersion.tryParse(bad), isNull); }
  });

  test('every author status and its review/withdrawal reason survives parsing', () {
    for (final status in WorkshopSubmissionStatus.values) {
      final row = WorkshopSubmission.fromJson(workshopSubmissionJson(status: status.name));
      expect(row.status, status);
      if (status == WorkshopSubmissionStatus.rejected) expect(row.reviewReason, 'review reason');
      if (status == WorkshopSubmissionStatus.withdrawn) expect(row.withdrawalReason, 'author withdrew');
    }
  });
}
