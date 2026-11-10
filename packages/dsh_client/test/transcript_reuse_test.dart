// What the transcript hands out stays the same object while nothing about it
// changed: the chat list keeps those rows (values are covered by the
// full-build oracle in transcript_incremental_test.dart).

import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  var seq = 0;
  late ChatTranscript t;

  void log(String type, Map<String, Object?> data) => t.apply(
    parseFollowFrame('s', {
      'type': 'event',
      'event': {'seq': ++seq, 'time': 1000 + seq, 'type': type, 'data': data},
    }),
  );
  void call(String id) => log('tool/call', {
    'turn': 1,
    'step': 1,
    'callId': id,
    'name': 'bash',
    'arguments': jsonEncode({'command': id}),
  });
  void result(String id) => log('tool/result', {
    'turn': 1,
    'step': 1,
    'message': {
      'role': 'tool',
      'toolCallId': id,
      'content': [
        {'type': 'text', 'text': 'ok'},
      ],
    },
  });
  ToolChatItem tool(String id) => t.items.whereType<ToolChatItem>().firstWhere((item) => item.callId == id);

  setUp(() {
    seq = 0;
    t = ChatTranscript();
    t.apply(SessionSnapshotEvent.fromJson('s', {'cursor': 0, 'records': const <Object?>[]}));
    log('turn/start', {'turn': 1});
    log('user/message', {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'go'},
      ],
      'source': {'kind': 'user'},
    });
  });

  test('calls nothing happened to keep their item; the one that changed gets a new one', () {
    call('a');
    call('b');
    final a = tool('a');
    final b = tool('b');
    call('c');
    expect(tool('a'), same(a));
    expect(tool('b'), same(b));
    result('b');
    expect(tool('a'), same(a));
    expect(tool('b'), isNot(same(b)));
    expect(tool('b').status, ToolStatus.succeeded);
    final done = tool('b');
    log('turn/end', {
      'turn': 1,
      'reason': {'kind': 'completed'},
    });
    // The turn ended before a and c had a result: they change, b does not.
    expect(tool('a').status, ToolStatus.cancelled);
    expect(tool('b'), same(done));
  });

  test('an approval waiting on a call changes that call only', () {
    call('a');
    call('b');
    final a = tool('a');
    t.apply(ApprovalRequestedEvent(const ApprovalRequest(eventId: 'e', sessionId: 's', toolName: 'bash', callId: 'b')));
    expect(tool('a'), same(a));
    expect(tool('b').status, ToolStatus.awaitingApproval);
    final waiting = tool('b');
    t.apply(const HostRequestCancelledEvent('e'));
    expect(tool('a'), same(a));
    expect(tool('b'), isNot(same(waiting)));
  });

  test('events that show nothing keep the items list itself', () {
    call('a');
    final items = t.items;
    log('permission/preset', {'preset': 'auto'});
    log('session/title', {'title': 'A title'});
    log('turn/start', {'turn': 2});
    log('some/unknown', {'x': 1});
    expect(t.items, same(items));
    expect(t.title, 'A title');
    call('b');
    expect(t.items, isNot(same(items)));
    expect(t.items.whereType<ToolChatItem>().first, same(items.whereType<ToolChatItem>().first));
  });
}
