import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/chat_transcript_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late ChatTranscriptStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chat_store_test');
    store = ChatTranscriptStore(root, maxEntriesPerSession: 4, maxSessions: 2);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('appends durable items and reads them back in order', () async {
    await store.append('ssh:h1', 's1', 1, {'type': 'item', 'seq': 1});
    await store.append('ssh:h1', 's1', 2, {'type': 'item', 'seq': 2});
    final entries = await store.read('ssh:h1', 's1');
    expect(entries.map((e) => e['seq']), [1, 2]);
    expect((entries.last['item'] as Map)['seq'], 2);
  });

  test('a snapshot replaces the stored log', () async {
    await store.append('ssh:h1', 's1', 1, {'type': 'item'});
    await store.appendSnapshot('ssh:h1', 's1', 9, {'type': 'snapshot', 'cursor': 9});
    final entries = await store.read('ssh:h1', 's1');
    expect(entries, hasLength(1));
    expect(entries.single['snapshot'], 9);
    expect((entries.single['item'] as Map)['cursor'], 9);
  });

  test('reading a long log compacts it to the newest entries', () async {
    for (var seq = 1; seq <= 12; seq++) {
      await store.append('ssh:h1', 's1', seq, {'seq': seq});
    }
    final entries = await store.read('ssh:h1', 's1');
    expect(entries, hasLength(12), reason: 'read returns what was written');
    final reread = await store.read('ssh:h1', 's1');
    expect(reread.length, lessThanOrEqualTo(4), reason: 'compacted to maxEntriesPerSession');
    expect((reread.last['item'] as Map)['seq'], 12);
  });

  test('prunes the oldest session files beyond maxSessions', () async {
    for (final session in ['a', 'b', 'c']) {
      await store.append('ssh:h1', session, 1, {'seq': 1});
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList();
    expect(files.length, lessThanOrEqualTo(2));
    expect(files, contains('c.jsonl'));
    expect(files, isNot(contains('a.jsonl')));
  });

  test('a corrupt line is skipped instead of losing the whole log', () async {
    await store.append('ssh:h1', 's1', 1, {'seq': 1});
    final file = root
        .listSync(recursive: true)
        .whereType<File>()
        .first;
    await file.writeAsString('not json\n', mode: FileMode.append);
    final entries = await store.read('ssh:h1', 's1');
    expect(entries, hasLength(1));
    expect(jsonEncode(entries.single), contains('"seq":1'));
  });
}
