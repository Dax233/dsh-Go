// Work-count guard for streaming: while a reply or a tool call's arguments
// stream in, only the row being written may rebuild, and the row model is not
// derived again per delta. Transport is the only fake: the transcript, the
// controller and the list are real. Counts, not frame times.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/notice_row.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;
}

const _session = 's';
const _deltas = 20;

/// Three finished turns (each a prompt, a tool call and an answer), then a
/// running fourth turn that has already finished one tool call.
List<Map<String, Object?>> _history() {
  final log = <Map<String, Object?>>[];
  var time = DateTime(2026, 11, 10, 9).millisecondsSinceEpoch;
  void ev(String type, Map<String, Object?> data) =>
      log.add({'type': type, 'seq': log.length + 1, 'time': time += 1000, 'data': data});
  void prompt(String text) => ev('user/message', {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
    'source': {'kind': 'user'},
  });
  void step(int turn, int step, {String text = '', String? call}) {
    ev('assistant/message', {
      'turn': turn,
      'step': step,
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'reasoning', 'text': '想一想第 $step 步'},
          if (text.isNotEmpty) {'type': 'text', 'text': text},
          if (call != null)
            {
              'type': 'tool-call',
              'id': call,
              'name': 'bash',
              'arguments': jsonEncode({'command': 'echo $call'}),
            },
        ],
        'source': {'kind': 'llm', 'model': 'deepseek-flash'},
      },
    });
    if (call == null) return;
    ev('tool/call', {
      'turn': turn,
      'step': step,
      'callId': call,
      'name': 'bash',
      'arguments': jsonEncode({'command': 'echo $call'}),
    });
    ev('tool/result', {
      'turn': turn,
      'step': step,
      'message': {
        'role': 'tool',
        'toolCallId': call,
        'content': [
          {'type': 'text', 'text': call},
        ],
      },
    });
  }

  for (var turn = 1; turn <= 3; turn++) {
    ev('turn/start', {'turn': turn});
    prompt('第 $turn 个问题');
    step(turn, 1, call: 'c$turn');
    step(turn, 2, text: '**第 $turn 个回答**\n\n- 一\n- 二\n\n`code` 和一段正文。');
    ev('turn/end', {
      'turn': turn,
      'reason': {'kind': 'completed'},
    });
  }
  ev('turn/start', {'turn': 4});
  prompt('第 4 个问题');
  step(4, 1, call: 'c4');
  return log;
}

class _Guard {
  _Guard() {
    container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: true))),
        settingsProvider.overrideWith(TestSettings.new),
        sessionArtifactsProvider(_session).overrideWithValue(const []),
      ],
    );
    container.listen(chatProvider(_session), (_, _) {});
  }

  final client = _Client();
  late final ProviderContainer container;
  final history = _history();
  late final int seq = history.length;
  final time = DateTime(2026, 11, 10, 10);
  var _index = 0;

  ChatState get state => container.read(chatProvider(_session));

  /// The history, with [queued] waiting in the inbox for the next turn.
  void snapshot({List<String> queued = const []}) {
    client.events.add(
      parseFollowFrame(_session, {
        'type': 'snapshot',
        'header': {'id': _session, 'createdAt': 1792700000000},
        'cursor': seq,
        'records': [
          for (final event in history) {'type': 'event', 'event': event},
        ],
        'hasMore': false,
        'projections': {
          'asOfSeq': seq,
          'values': {
            'inbox': {
              'next-turn': [
                for (final (i, text) in queued.indexed)
                  {
                    'id': 'inbox-$i',
                    'role': 'user',
                    'content': [
                      {'type': 'text', 'text': text},
                    ],
                    'source': {'kind': 'user'},
                  },
              ],
              'next-step': <Object?>[],
            },
          },
        },
      }),
    );
    client.events.add(const SessionStatusEvent(_session, true));
  }

  void startStream() => client.events.add(AssistantStreamStarted('attempt', 0, turn: 4, step: 2, startedAfterSeq: seq));

  void chunk(StreamChunk chunk) =>
      client.events.add(AssistantChunkEvent('attempt', 0, index: _index++, time: time, chunk: chunk));

  Future<void> mount(WidgetTester tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme(Brightness.light),
          home: const Scaffold(body: ChatList(sessionId: _session, topInset: 0, bottomInset: 0)),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Unmounts and disposes before the test ends: the controller's timers
  /// go with the container.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    dispose();
    await tester.pump(const Duration(seconds: 1));
  }

  var _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
    unawaited(client.events.close());
  }
}

/// Builds of row widgets during [body], split into the row being written
/// (a streaming reply or tool call) and every other row.
Future<({int done, int live, int derivations})> _count(Future<void> Function() body) async {
  var done = 0;
  var live = 0;
  final previous = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    previous?.call(element, builtOnce);
    switch (element.widget) {
      case AssistantMessage(:final item) when item.streaming:
        live++;
      case ToolRow(:final item) when item.status == ToolStatus.streaming:
        live++;
      case ToolGroup(:final tools) when tools.any((tool) => tool.status == ToolStatus.streaming):
        live++;
      case AssistantMessage() || ToolRow() || ToolGroup() || UserBubble() || TurnProcess() || NoticeRow():
        done++;
    }
  };
  final derived = debugDeriveRowsCount;
  try {
    await body();
  } finally {
    debugOnRebuildDirtyWidget = previous;
  }
  return (done: done, live: live, derivations: debugDeriveRowsCount - derived);
}

void main() {
  setUpAll(loadTestFonts);

  Future<void> streamText(WidgetTester tester, {List<String> queued = const []}) async {
    final g = _Guard();
    addTearDown(g.dispose);
    await g.mount(tester);
    g.snapshot(queued: queued);
    await g.settle(tester);
    g.startStream();
    g.chunk(const TextDeltaChunk(0, '开始'));
    await g.settle(tester);
    expect(g.state.pending, hasLength(queued.length));
    expect(find.byType(UserBubble), findsWidgets);

    final counts = await _count(() async {
      for (var delta = 0; delta < _deltas; delta++) {
        g.chunk(TextDeltaChunk(0, ' 第$delta段'));
        await tester.pump(const Duration(milliseconds: 32));
      }
    });
    expect(tester.takeException(), isNull);
    final draft = g.state.items.whereType<AssistantChatItem>().last;
    expect(draft.streaming, isTrue);
    expect(draft.text, contains('第${_deltas - 1}段'));
    debugPrint(
      '[GUARD] text stream, queued=${queued.length}, deltas=$_deltas: '
      'finished-row builds=${counts.done} live-row builds=${counts.live} deriveRows=${counts.derivations}',
    );
    expect(counts.live, greaterThan(0), reason: 'the reply being written rebuilds');
    expect(counts.done, 0, reason: 'finished rows must not rebuild while a reply streams');
    expect(counts.derivations, 0, reason: 'a text delta must not derive the rows again');
    await g.unmount(tester);
  }

  testWidgets('a streaming reply rebuilds only its own row', (tester) async {
    await streamText(tester);
  });

  testWidgets('a streaming reply with queued messages derives no rows per delta', (tester) async {
    await streamText(tester, queued: ['排队一', '排队二']);
  }, skip: true); // A2

  testWidgets('streaming tool arguments rebuild only the tool being written', (tester) async {
    final g = _Guard();
    addTearDown(g.dispose);
    await g.mount(tester);
    g.snapshot(queued: ['排队一']);
    await g.settle(tester);
    g.startStream();
    g.chunk(const ReasoningDeltaChunk(0, '要先看一下目录'));
    g.chunk(const BlockStartChunk(1, 'tool-call'));
    g.chunk(const ToolCallDeltaChunk(1, id: 'c5', name: 'bash', argumentsDelta: '{"command": "ls'));
    await g.settle(tester);
    expect(g.state.items.last, isA<ToolChatItem>().having((t) => t.status, 'status', ToolStatus.streaming));

    final counts = await _count(() async {
      for (var delta = 0; delta < _deltas; delta++) {
        g.chunk(ToolCallDeltaChunk(1, id: 'c5', argumentsDelta: ' dir$delta'));
        await tester.pump(const Duration(milliseconds: 32));
      }
    });
    expect(tester.takeException(), isNull);
    expect((g.state.items.last as ToolChatItem).arguments, endsWith('dir${_deltas - 1}'));
    debugPrint(
      '[GUARD] tool arguments stream, deltas=$_deltas: '
      'finished-row builds=${counts.done} live-row builds=${counts.live} deriveRows=${counts.derivations}',
    );
    expect(counts.live, greaterThan(0), reason: 'the tool call being written rebuilds');
    expect(counts.done, 0, reason: 'finished rows must not rebuild while tool arguments stream');
    expect(counts.derivations, 0, reason: 'an argument delta must not derive the rows again');
    await g.unmount(tester);
  }, skip: true); // A2
}
