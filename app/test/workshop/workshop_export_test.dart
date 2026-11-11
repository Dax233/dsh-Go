import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/workshop/workshop_export.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('workshop-export'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('canonical destination queue spans independent writers and path aliases', () async {
    final real = Directory('${temp.path}/real')..createSync();
    final alias = Link('${temp.path}/alias')..createSync(real.path);
    final firstTarget = await workshopExportTarget(File('${real.path}/new/output.zip'));
    final secondTarget = await workshopExportTarget(File('${alias.path}/new/./output.zip'));
    expect(secondTarget.path, firstTarget.path);
    final entered = Completer<void>(), release = Completer<void>();
    final first = workshopCommitExport(firstTarget, (staging) async {
      entered.complete();
      await release.future;
      await staging.writeAsString('first');
    });
    await entered.future;
    var secondWrites = 0;
    final second = expectLater(workshopCommitExport(secondTarget, (staging) async {
      secondWrites++;
      await staging.writeAsString('second');
    }), workshopError('workshop_export_exists'));
    await Future<void>.delayed(Duration.zero);
    expect(secondWrites, 0);
    release.complete();
    await first;
    await second;
    expect(firstTarget.readAsStringSync(), 'first');
    expect(secondWrites, 0);
  });

  test('commit rechecks a destination created while generation was pending', () async {
    final target = await workshopExportTarget(File('${temp.path}/output.zip'));
    final entered = Completer<void>(), release = Completer<void>();
    final result = expectLater(workshopCommitExport(target, (staging) async {
      await staging.writeAsString('new');
      entered.complete();
      await release.future;
    }), workshopError('workshop_export_exists'));
    await entered.future;
    target.writeAsStringSync('keep');
    release.complete();
    await result;
    expect(target.readAsStringSync(), 'keep');
    expect(temp.listSync().where((e) => e.path.contains('.workshop-')), isEmpty);
  });

  test('a dangling destination link is not treated as an absent file', () async {
    final link = Link('${temp.path}/output.zip')..createSync('${temp.path}/missing');
    final target = await workshopExportTarget(File(link.path));
    await expectLater(workshopCommitExport(target, (staging) async { await staging.writeAsString('new'); }),
      workshopError('workshop_export_exists'));
    expect(Link(link.path).existsSync(), isTrue);
  });

  test('real pet and companion exports share the same final destination gate', () async {
    final pets = PetLibrary(() async => Directory('${temp.path}/pets'));
    await pets.install(workshopZip(temp, {'pack.json': utf8.encode(jsonEncode(workshopPet())), 'idle.png': workshopPng()}));
    final companion = CompanionPackStore(Directory('${temp.path}/companion'), expectedRuntime: workshopRuntimeDigest());
    await companion.install(workshopZip(temp, {...workshopRuntime(), ...workshopCharacter()}).path);
    final target = File('${temp.path}/shared.zip');
    Future<Object> attempt(Future<File> value) async {
      try { return await value; } on WorkshopException catch (error) { return error; }
    }
    final results = await Future.wait([
      attempt(pets.exportZip('user-cat', target)), attempt(companion.exportZip(target)),
    ]);
    expect(results.whereType<File>(), hasLength(1));
    expect(results.whereType<WorkshopException>().single.code, 'workshop_export_exists');
    final members = workshopUnzip(target);
    expect(members.containsKey('pack.json') != members.containsKey('character/character.json'), isTrue);
  });
}
