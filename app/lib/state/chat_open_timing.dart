import 'dart:collection';

/// Recent cold/warm open timings, for the diagnostics bundle only.
///
/// "Entering a session takes minutes" cannot be judged from a screenshot: the
/// cost is disk seed + follow snapshot + history fill over a slow link. Each
/// open appends one entry here so an exported bundle carries the numbers
/// instead of a guess.
class ChatOpenTiming {
  ChatOpenTiming._();

  static final Queue<Map<String, Object?>> _recent = Queue<Map<String, Object?>>();
  static const int _max = 20;

  static void add({
    required String host,
    required String sessionId,
    required bool seededFromDisk,
    required int seedMs,
    required int firstPaintMs,
    int? seedPaintMs,
    int? snapshotMs,
    int? events,
    int? cursor,
  }) {
    _recent.addFirst(<String, Object?>{
      'at': DateTime.now().toUtc().toIso8601String(),
      'host': host,
      'session': sessionId,
      'seededFromDisk': seededFromDisk,
      'seedMs': seedMs,
      'seedPaintMs': ?seedPaintMs,
      'firstPaintMs': firstPaintMs,
      'snapshotMs': ?snapshotMs,
      // How much history the screen ended up with: a replacement snapshot
      // drops the cached older events, and a thin number is how "only the last
      // exchange shows" reaches a bug report.
      'events': ?events,
      'cursor': ?cursor,
    });
    while (_recent.length > _max) {
      _recent.removeLast();
    }
  }

  static List<Map<String, Object?>> snapshot() => List<Map<String, Object?>>.unmodifiable(_recent);
}
