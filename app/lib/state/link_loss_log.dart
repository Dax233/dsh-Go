import 'dart:collection';

/// Why the remote link was lost, for the diagnostics bundle only.
///
/// The trace on the host records what the Host saw; this records what the
/// client believed (SSH transport ended, keepalive gave up, mux probe, ready
/// timeout). "It disconnects all the time" cannot be fixed without knowing
/// which of those fired, and they have different fixes.
class LinkLossLog {
  LinkLossLog._();

  static final Queue<Map<String, Object?>> _recent = Queue<Map<String, Object?>>();
  static const int _max = 30;

  static void add(String source, String reason, {Map<String, Object?>? fields}) {
    _recent.addFirst(<String, Object?>{
      'at': DateTime.now().toUtc().toIso8601String(),
      'source': source,
      'reason': reason,
      ...?fields,
    });
    while (_recent.length > _max) {
      _recent.removeLast();
    }
  }

  static List<Map<String, Object?>> snapshot() => List<Map<String, Object?>>.unmodifiable(_recent);
}
