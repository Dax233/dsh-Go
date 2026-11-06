import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// On-disk cache for one host's session logs.
///
/// The chat screen rebuilds its transcript from a Host snapshot whenever it is
/// opened cold or the follow stream is reopened. This store keeps the raw
/// session/follow items (JSON) so a cold open can paint at once and then
/// reconcile only the tail.
///
/// Layout: `<root>/<host>/<sessionId>.jsonl`, one raw item per line:
/// `{"seq":123,"item":{...}}`. Append-only; compaction rewrites the file.
class ChatTranscriptStore {
  ChatTranscriptStore(this.root, {this.maxEntriesPerSession = 400, this.maxSessions = 8});

  final Directory root;
  final int maxEntriesPerSession;
  final int maxSessions;

  /// Appends one durable item for [hostKey]/[sessionId]. Ignores failures:
  /// the cache is an optimisation, never a correctness dependency.
  Future<void> append(String hostKey, String sessionId, int seq, Object? item) async {
    try {
      final file = await _file(hostKey, sessionId);
      final line = jsonEncode({'seq': seq, 'item': item});
      await file.writeAsString('$line\n', mode: FileMode.append, flush: false);
    } catch (_) {
      // Best effort.
    }
  }

  /// Replaces the stored log with [item] as its new base snapshot: a snapshot
  /// already carries the window, so replaying it plus later items rebuilds the
  /// transcript, and the file stays bounded.
  Future<void> appendSnapshot(String hostKey, String sessionId, int cursor, Object? item) async {
    try {
      final file = await _file(hostKey, sessionId);
      await file.writeAsString(jsonEncode({'snapshot': cursor, 'item': item}) + '\n', flush: false);
    } catch (_) {
      // Best effort.
    }
  }

  /// The cached items for [hostKey]/[sessionId], oldest first.
  Future<List<Map<String, Object?>>> read(String hostKey, String sessionId) async {
    try {
      final file = await _file(hostKey, sessionId);
      if (!await file.exists()) return const [];
      final lines = await file.readAsLines();
      final out = <Map<String, Object?>>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line);
        if (decoded is Map<String, Object?>) out.add(decoded);
      }
      // Append-only files outgrow the cap; compact on read (the rare path)
      // instead of paying a rewrite on every append.
      if (lines.length > maxEntriesPerSession * 2) {
        await _rewrite(file, out.skip(out.length - maxEntriesPerSession).toList());
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _rewrite(File file, List<Map<String, Object?>> entries) async {
    try {
      final buffer = StringBuffer();
      for (final entry in entries) {
        buffer.writeln(jsonEncode(entry));
      }
      await file.writeAsString(buffer.toString(), flush: false);
    } catch (_) {}
  }

  Future<void> clear(String hostKey, String sessionId) async {
    try {
      final file = await _file(hostKey, sessionId);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<File> _file(String hostKey, String sessionId) async {
    final dir = Directory('${root.path}/${_safe(hostKey)}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/${_safe(sessionId)}.jsonl');
  }

  String _safe(String value) => value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
}

/// The process-wide transcript cache directory under the app's support dir.
final chatTranscriptStoreProvider = FutureProvider<ChatTranscriptStore>((ref) async {
  final base = await getApplicationSupportDirectory();
  return ChatTranscriptStore(Directory('${base.path}/chat_transcripts'));
});
