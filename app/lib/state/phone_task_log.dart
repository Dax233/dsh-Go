import 'dart:collection';

/// Recent phone-task lifecycle facts, for the diagnostics bundle only.
///
/// "The overlay stayed and the pet never came back" can mean two very
/// different things: the task never ended (nobody claimed the turn end) or it
/// ended and the pet's own gate kept it hidden. A bundle that records both the
/// turn-end claim and the native finish answer separates them without guessing.
class PhoneTaskLog {
  PhoneTaskLog._();

  static final Queue<Map<String, Object?>> _recent = Queue<Map<String, Object?>>();
  static const int _max = 40;

  static void add(String event, [Map<String, Object?>? fields]) {
    _recent.addFirst(<String, Object?>{
      'at': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      ...?fields,
    });
    while (_recent.length > _max) {
      _recent.removeLast();
    }
  }

  static List<Map<String, Object?>> snapshot() => List<Map<String, Object?>>.unmodifiable(_recent);
}
