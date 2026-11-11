import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'workshop_models.dart';

/// Resolve the existing parent, including aliases, without following the
/// destination itself. A dangling destination link is still an existing item.
Future<File> workshopExportTarget(File destination) async {
  try {
    final target = File(destination.absolute.uri.normalizePath().toFilePath());
    var parent = target.parent;
    final tail = <String>[target.uri.pathSegments.last];
    while (!await parent.exists()) {
      final next = parent.parent;
      if (next.path == parent.path) workshopInvalid('workshop_storage');
      tail.insert(0, parent.uri.pathSegments.lastWhere((part) => part.isNotEmpty));
      parent = next;
    }
    return File([await parent.resolveSymbolicLinks(), ...tail].join(Platform.pathSeparator));
  } on FileSystemException catch (error) {
    throw _exportStorage(error);
  }
}

final _exports = <String, Future<void>>{};

/// Pet and companion export call this on the owning App isolate, before
/// compute starts. The shared destination queue therefore covers both kinds
/// and all store instances, rather than a separate queue inside each isolate.
Future<void> workshopCommitExport(File target, Future<void> Function(File staging) write) {
  final key = target.absolute.uri.normalizePath().toString();
  final previous = _exports[key] ?? Future<void>.value();
  final Future<void> run = previous.then((_) async {
    File? staging;
    try {
      Future<void> absent() async {
        if (await FileSystemEntity.type(target.path, followLinks: false) != FileSystemEntityType.notFound) {
          workshopInvalid('workshop_export_exists');
        }
      }
      await absent();
      await target.parent.create(recursive: true);
      final random = Random.secure();
      final nonce = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final temporary = File('${target.parent.path}/.workshop-export-$nonce.part');
      staging = temporary;
      await write(temporary);
      if (await FileSystemEntity.type(temporary.path, followLinks: false) != FileSystemEntityType.file) {
        workshopInvalid('workshop_storage');
      }
      // Check at commitment as well: another owner may have created the path
      // while the archive was being generated. Never replace that file.
      await absent();
      await temporary.rename(target.path);
    } on FileSystemException catch (error) {
      throw _exportStorage(error);
    } finally {
      final temporary = staging;
      try { if (temporary != null && await temporary.exists()) await temporary.delete(); }
      on FileSystemException { /* Only the private staging file may remain. */ }
    }
  });
  final tail = run.then<void>((_) {}, onError: (_) {});
  _exports[key] = tail;
  unawaited(tail.then((_) { if (identical(_exports[key], tail)) _exports.remove(key); }));
  return run;
}

WorkshopException _exportStorage(FileSystemException error) => WorkshopException(
  const {28, 122}.contains(error.osError?.errorCode) ? 'workshop_no_space' : 'workshop_storage');
