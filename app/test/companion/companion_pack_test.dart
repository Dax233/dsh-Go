import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:flutter_test/flutter_test.dart';

const _core = 'runtime/live2dcubismcore.min.js';

Map<String, List<int>> _runtime() => {_core: utf8.encode('core'), 'runtime/cubism-framework.js': utf8.encode('fw')};

Map<String, List<int>> _character() => {
  'character/m.model3.json': utf8.encode('{}'),
  'character/m.moc3': [1, 2, 3],
  'character/character.json': utf8.encode('{"name":"鲸鱼娘","author":"某人"}'),
  'character/贴图 1/texture_00.png': [4, 5],
};

String _digest(Map<String, List<int>> files) => runtimeDigest({
  for (final e in files.entries)
    if (e.key.startsWith('runtime/')) e.key: sha256.convert(e.value).toString(),
});

void main() {
  late Directory root;
  late CompanionPackStore store;

  String zip(Map<String, List<int>> files) {
    final archive = Archive();
    files.forEach((name, data) => archive.add(ArchiveFile.bytes(name, data)));
    final path = '${root.path}/in-${DateTime.now().microsecondsSinceEpoch}.zip';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  Matcher problem(CompanionPackProblem expected) =>
      throwsA(isA<CompanionPackException>().having((e) => e.problem, 'problem', expected));

  setUp(() {
    root = Directory.systemTemp.createTempSync('companion-pack');
    store = CompanionPackStore(root, expectedRuntime: _digest(_runtime()));
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('runtimeDigest does not depend on order', () {
    expect(runtimeDigest({'b': '2', 'a': '1'}), runtimeDigest({'a': '1', 'b': '2'}));
    expect(runtimeDigest({'a': '1'}), isNot(runtimeDigest({'a': '2'})));
  });

  test('isSafePackPath', () {
    for (final ok in ['a', 'a/b.png', '贴图 1/texture.png', 'a..b/c']) {
      expect(isSafePackPath(ok), isTrue, reason: ok);
    }
    for (final bad in ['', '/etc/passwd', '../x', 'a/../b', 'a/./b', r'a\b', 'a//b', 'a/']) {
      expect(isSafePackPath(bad), isFalse, reason: bad);
    }
  });

  test('installs a full pack and reads its character', () async {
    expect(await store.installed(), isFalse);
    await store.install(zip({..._runtime(), ..._character()}));
    expect(await store.installed(), isTrue);
    expect(File('${store.pack.path}/character/贴图 1/texture_00.png').readAsBytesSync(), [4, 5]);
    final index = jsonDecode(File('${store.pack.path}/character/index.json').readAsStringSync()) as List;
    expect(index, contains('m.model3.json'));
    final character = await store.character();
    expect(character.name, '鲸鱼娘');
    expect(character.author, '某人');
    expect(character.license, isNull);
  });

  test('refuses a runtime it does not know, and keeps what was there', () async {
    await store.install(zip({..._runtime(), ..._character()}));
    final other = {
      ..._runtime(),
      _core: utf8.encode('something else'),
      ..._character(),
      'character/other.model3.json': utf8.encode('{}'),
    };
    await expectLater(store.install(zip(other)), problem(CompanionPackProblem.runtimeMismatch));
    expect(File('${store.pack.path}/$_core').readAsStringSync(), 'core');
    expect(File('${store.pack.path}/character/other.model3.json').existsSync(), isFalse);
    expect(Directory('${root.path}/pack.staging').existsSync(), isFalse);
  });

  test('a character alone keeps the installed runtime', () async {
    await store.install(zip({..._runtime(), ..._character()}));
    await store.install(
      zip({'character/new.model3.json': utf8.encode('{}'), 'character/character.json': utf8.encode('{"name":"新角色"}')}),
    );
    expect((await store.character()).name, '新角色');
    expect(File('${store.pack.path}/$_core').readAsStringSync(), 'core');
    expect(File('${store.pack.path}/character/m.moc3').existsSync(), isFalse);
  });

  test('a character alone needs a runtime first', () async {
    await expectLater(store.install(zip(_character())), problem(CompanionPackProblem.noRuntime));
  });

  test('no scripts or pages among character files', () async {
    for (final name in ['character/run.js', 'character/index.html', 'character/x.svg', 'character/noext']) {
      await expectLater(
        store.install(zip({..._runtime(), ..._character(), name: utf8.encode('x')})),
        problem(CompanionPackProblem.forbiddenFile),
        reason: name,
      );
    }
  });

  test('no paths out of the pack', () async {
    for (final name in ['../evil.png', 'character/../../evil.png', 'other/file.png', '/abs/file.png']) {
      await expectLater(
        store.install(zip({..._runtime(), ..._character(), name: utf8.encode('x')})),
        problem(CompanionPackProblem.unsafePath),
        reason: name,
      );
    }
    expect(File('${root.path}/evil.png').existsSync(), isFalse);
  });

  test('needs a model', () async {
    await expectLater(
      store.install(zip({..._runtime(), 'character/character.json': utf8.encode('{}')})),
      problem(CompanionPackProblem.noModel),
    );
  });

  test('something that is not a zip', () async {
    final path = '${root.path}/not.zip';
    File(path).writeAsStringSync('hello');
    await expectLater(store.install(path), problem(CompanionPackProblem.notAPack));
  });

  test('remove', () async {
    await store.install(zip({..._runtime(), ..._character()}));
    await store.remove();
    expect(await store.installed(), isFalse);
    await store.remove();
  });
}
