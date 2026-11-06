import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

// The disk transcript cache depends on two promises from the follow client:
// that the raw snapshot arrives with its cursor, and that every durable item
// arrives with its seq and re-parses to the same event. This test pins both.

class _Carrier extends DshCarrier {
  final links = <_Link>[];
  @override
  String get kind => 'raw-log-hooks';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      throw StateError('no unary calls expected');
  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = _Link();
    links.add(link);
    return link;
  }

  @override
  Future<void> close() async {}
}

class _Link implements DshMuxLink {
  late DshMuxFrameHandler frame;
  String? eventsId;
  String? followId;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => frame = onFrame;
  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      eventsId = streamId;
    } else {
      followId = streamId;
    }
  }

  void ready() => frame({
    'type': 'item',
    'streamId': eventsId!,
    'value': {
      'type': 'ready',
      'clientId': 'raw-log-client',
      'host': {'home': '/synthetic'},
    },
  });
  void item(Object? value) => frame({'type': 'item', 'streamId': followId!, 'value': value});
  @override
  void cancel(String streamId) {}
  @override
  Future<void> close(int code, String reason) async {}
  @override
  void sendItem(String streamId, Object? value) {}
  @override
  void endUplink(String streamId) {}
}

Future<void> pump(FakeAsync clock) async {
  for (var turn = 0; turn < 32; turn++) {
    clock.elapse(Duration.zero);
    await Future<void>.value();
  }
}

void main() {
  final frames = loadJsonl('follow_reply_ok.jsonl').cast<Map<String, Object?>>();
  final snapshot = frames.first;
  final sessionId = (snapshot['header']! as Map)['id']! as String;
  final cursor = (snapshot['cursor']! as num).toInt();
  final events = [
    for (final f in frames)
      if (f['type'] == 'event') f,
  ];

  test('raw hooks expose the snapshot cursor and durable items that re-parse', () async {
    final async = FakeAsync();
    final carrier = _Carrier();
    final client = async.run(
      (_) => DshClient.withCarrier(carrier, muxOptions: const MuxOptions(retryCaps: [Duration.zero])),
    );
    final snapshots = <int, Object?>{};
    final rawItems = <int, Object?>{};
    final sub = async.run(
      (_) => client
          .watch(
            sessionId,
            options: WatchOptions(
              includeHostEvents: false,
              onRawSnapshot: (at, item) => snapshots[at] = item,
              onRawItem: (seq, item) => rawItems[seq] = item,
            ),
          )
          .listen((_) {}, onError: (_) {}),
    );
    try {
      await pump(async);
      carrier.links.single.ready();
      await pump(async);
      carrier.links.single.item(snapshot);
      await pump(async);

      expect(snapshots.keys, [cursor], reason: 'the snapshot arrives with its cursor');
      expect(
        parseFollowFrame(sessionId, snapshots[cursor]),
        isA<SessionSnapshotEvent>(),
        reason: 'a stored snapshot must re-parse on a cold open',
      );

      // Every durable record after the snapshot carries its seq and re-parses.
      final after = events.where((f) => (f['event']! as Map)['seq'] as int > cursor).take(3).toList();
      expect(after, isNotEmpty);
      for (final record in after) {
        carrier.links.single.item(record);
        await pump(async);
      }
      expect(rawItems.keys, [for (final r in after) (r['event']! as Map)['seq'] as int]);
      for (final entry in rawItems.entries) {
        final parsed = parseFollowFrame(sessionId, entry.value);
        expect(parsed, isA<SessionLogEvent>());
        expect((parsed as SessionLogEvent).seq, entry.key);
      }
    } finally {
      await sub.cancel();
      await client.close();
    }
  });
}
