import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
      return out;
    } catch (_) {
      return const [];
    }
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
