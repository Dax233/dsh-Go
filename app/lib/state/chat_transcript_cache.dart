import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Keeps the last few sessions' [ChatTranscript] instances across screens.
///
/// The chat controller is `autoDispose` and normally drops its transcript when
/// its screen leaves, so switching back rebuilt the whole log from a fresh
/// `session/follow` snapshot (up to [WatchOptions.maxMessages] events, about
/// 1 MB on a long conversation). Holding the transcript here makes a switch
/// back a cache hit: the screen renders at once and the follow repairs only
/// the seq gap after [ChatTranscript.newestSeq] (`WatchOptions.initialSeq`),
/// while the existing history fill downloads just the delta.
///
/// Entries are host-scoped (the same session id on another host is another
/// log) and evicted least-recently-used first: [maxSessions] bounds memory,
/// not correctness. A transcript whose cursor is behind the Host snapshot
/// (the log was reset upstream) is replaced by that snapshot on the next
/// follow.
class ChatTranscriptCache {
  ChatTranscriptCache({this.maxSessions = 8});

  final int maxSessions;
  final Map<String, ChatTranscript> _entries = <String, ChatTranscript>{};

  static String keyFor(String hostKey, String sessionId) => '$hostKey\u0000$sessionId';

  /// The transcript for [sessionId] on [hostKey], new or last used.
  ChatTranscript acquire(String hostKey, String sessionId) {
    final key = keyFor(hostKey, sessionId);
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return cached;
    }
    final fresh = ChatTranscript();
    _entries[key] = fresh;
    while (_entries.length > maxSessions) {
      _entries.remove(_entries.keys.first);
    }
    return fresh;
  }

  /// Drops a cached transcript (deleted session, forgotten host).
  void evict(String hostKey, String sessionId) => _entries.remove(keyFor(hostKey, sessionId));

  int get length => _entries.length;

  void clear() => _entries.clear();
}

final chatTranscriptCacheProvider = Provider<ChatTranscriptCache>((ref) => ChatTranscriptCache());
