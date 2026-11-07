import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

SessionLogEvent event(int seq, String type, Map<String, Object?> data) =>
    SessionLogEvent.fromJson({'seq': seq, 'time': 1000 + seq, 'type': type, 'data': data});

SessionLogEvent step(int seq) => event(seq, 'step/start', {'turn': 1, 'step': seq});

SessionSnapshotEvent snapshot(
  List<SessionLogEvent> events, {
  bool hasMore = false,
  bool resync = false,
  int? cursor,
}) => SessionSnapshotEvent(
  sessionId: 'own',
  header: SessionHeader.fromJson({'id': 'own', 'version': 4, 'createdAt': 1000}),
  cursor: cursor ?? (events.isEmpty ? -1 : events.last.seq),
  events: events,
  hasMore: hasMore,
  projections: const SessionProjections(-1, {}),
  assistantRevision: 0,
  isResync: resync,
);

void main() {
  test('a continuing snapshot keeps the cached older history', () {
    final transcript = ChatTranscript()
      ..hasMoreHistory = true
      ..apply(snapshot([for (var i = 1; i <= 10; i++) step(i)], hasMore: true));
    expect(transcript.oldestSeq, 1);
    expect(transcript.hasMoreHistory, isTrue);

    // Warm window: the Host only sends the tail; the cached head survives.
    transcript.apply(
      snapshot([for (var i = 8; i <= 14; i++) step(i)]),
      preserveOlderHistory: true,
    );

    expect(transcript.oldestSeq, 1, reason: 'cached head preserved on a warm follow');
    expect(transcript.newestSeq, 14);
    expect(transcript.cursor, 14);
    expect(transcript.hasMoreHistory, isTrue, reason: 'older pages are still reachable');
    expect(transcript.events.map((e) => e.seq).toList(), [for (var i = 1; i <= 14; i++) i]);
  });

  test('without the warm flag the snapshot still replaces the log', () {
    final transcript = ChatTranscript()..apply(snapshot([for (var i = 1; i <= 10; i++) step(i)]));
    transcript.apply(snapshot([for (var i = 8; i <= 14; i++) step(i)]));
    expect(transcript.oldestSeq, 8);
  });

  test('a snapshot behind the cached log replaces it (Host reset the log)', () {
    final transcript = ChatTranscript()..apply(snapshot([for (var i = 1; i <= 10; i++) step(i)]));
    transcript.apply(
      snapshot([for (var i = 1; i <= 4; i++) step(i)], cursor: 4),
      preserveOlderHistory: true,
    );
    expect(transcript.oldestSeq, 1);
    expect(transcript.newestSeq, 4);
    expect(transcript.cursor, 4);
  });

  test('a seq hole between cache and snapshot is not preserved', () {
    final transcript = ChatTranscript()..apply(snapshot([for (var i = 1; i <= 5; i++) step(i)]));
    transcript.apply(
      snapshot([for (var i = 9; i <= 12; i++) step(i)]),
      preserveOlderHistory: true,
    );
    expect(transcript.oldestSeq, 9, reason: 'a hole means the snapshot must replace the log');
  });

  test('a warm snapshot that reports more history re-arms the paging affordance', () {
    // How the bug looked: the stored snapshot said "nothing older" (thin
    // window), so the flag started false; the live warm snapshot knows there
    // is more, but the keeps-older branch used to skip the assignment and the
    // screen lost its "load older" control entirely.
    final transcript = ChatTranscript()
      ..apply(snapshot([for (var i = 7; i <= 10; i++) step(i)]));
    expect(transcript.hasMoreHistory, isFalse);

    transcript.apply(
      snapshot([for (var i = 11; i <= 12; i++) step(i)], hasMore: true),
      preserveOlderHistory: true,
    );

    expect(transcript.oldestSeq, 7, reason: 'the cached head is kept');
    expect(transcript.hasMoreHistory, isTrue, reason: 'paging must stay reachable');
  });

  test('a warm snapshot without older history does not clear a reachable one', () {
    final transcript = ChatTranscript()
      ..apply(snapshot([for (var i = 1; i <= 10; i++) step(i)], hasMore: true));
    transcript.apply(
      snapshot([for (var i = 9; i <= 12; i++) step(i)]),
      preserveOlderHistory: true,
    );
    expect(transcript.hasMoreHistory, isTrue);
  });

  test('an empty warm snapshot keeps the cached history', () {
    final transcript = ChatTranscript()..apply(snapshot([for (var i = 1; i <= 5; i++) step(i)]));
    transcript.apply(snapshot(const [], cursor: 5), preserveOlderHistory: true);
    expect(transcript.oldestSeq, 1);
    expect(transcript.cursor, 5);
  });
}
