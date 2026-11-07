import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

// A reconnect fails every stream at once, and every owner opens again in the
// same turn. On a slow link those simultaneous opens are what re-breaks the
// fresh link, so the mux can space them (MuxOptions.reopenStagger). The default
// stays zero: only a carrier that opts in is affected.

class _Carrier extends DshCarrier {
  final links = <_Link>[];
  @override
  String get kind => 'reopen-stagger';
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
  final opened = <String>[];

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => frame = onFrame;
  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      eventsId = streamId;
    } else {
      opened.add(endpoint);
    }
  }

  void ready() => frame({
    'type': 'item',
    'streamId': eventsId!,
    'value': {
      'type': 'ready',
      'clientId': 'stagger-client',
      'host': {'home': '/synthetic'},
    },
  });
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
  for (var turn = 0; turn < 16; turn++) {
    clock.elapse(Duration.zero);
    await Future<void>.value();
  }
}

void main() {
  test('an opted-in stagger spaces the opens that follow one reconnect', () async {
    final clock = FakeAsync();
    final carrier = _Carrier();
    final client = clock.run(
      (_) => DshClient.withCarrier(
        carrier,
        muxOptions: const MuxOptions(reopenStagger: Duration(milliseconds: 50)),
      ),
    );
    clock.run((_) => unawaited(client.mux.ready()));
    await pump(clock);
    carrier.links.single.ready();
    await pump(clock);

    clock.run((_) {
      client.mux.open('stream/a', const {});
      client.mux.open('stream/b', const {});
      client.mux.open('stream/c', const {});
    });
    await pump(clock);
    expect(carrier.links.single.opened, ['stream/a'], reason: 'only the first goes immediately');

    clock.elapse(const Duration(milliseconds: 60));
    await pump(clock);
    expect(carrier.links.single.opened, ['stream/a', 'stream/b']);

    clock.elapse(const Duration(milliseconds: 120));
    await pump(clock);
    expect(carrier.links.single.opened, ['stream/a', 'stream/b', 'stream/c']);
  });

  test('without the option every open goes immediately', () async {
    final clock = FakeAsync();
    final carrier = _Carrier();
    final client = clock.run((_) => DshClient.withCarrier(carrier));
    clock.run((_) => unawaited(client.mux.ready()));
    await pump(clock);
    carrier.links.single.ready();
    await pump(clock);
    clock.run((_) {
      client.mux.open('stream/a', const {});
      client.mux.open('stream/b', const {});
    });
    await pump(clock);
    expect(carrier.links.single.opened, ['stream/a', 'stream/b']);
  });
}
