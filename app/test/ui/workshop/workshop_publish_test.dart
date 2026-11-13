// 投稿 page: every step it can show, driven by the real workshop controllers
// over the state layer's own fakes (no network, no files).

import 'dart:async';

import 'package:dsh_app/forum/forum_auth.dart';
import 'package:dsh_app/forum/forum_state.dart';
import 'package:dsh_app/state/workshop_auth_state.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/state/workshop_publication.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:dsh_app/state/workshop_publish_state.dart';
import 'package:dsh_app/ui/workshop/workshop_publish_page.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../shell/golden_harness.dart' show goldenApp;
import '../../state/workshop_auth_test_support.dart';
import '../../state/workshop_publish_test_support.dart';
import '../../workshop/support.dart' show workshopCaps;

const _companion = WorkshopPublishSource(kind: 'companion', localId: 'companion');

/// The page's world: a signed-in forum account that has already agreed to
/// the disclosure, a workshop that takes uploads, one pet to send.
class _World {
  _World({ForumAuthState? account}) : account = account ?? authSignedIn();

  final events = <String>[];
  final ForumAuthState account;
  late final preferences = PublishPreferences(events);
  late final client = PublishClient(events);
  late final drafts = PublishDrafts(events);
  List<WorkshopPublishSource> sources = [publishSource];
  Map<String, WorkshopException> issues = {};
  WorkshopPublishController Function()? publisher;
  int ids = 0;

  void capabilities({bool uploads = true, bool companion = true}) => client.value = WorkshopCapabilities.fromJson(
    workshopCaps(uploads: uploads, companion: companion, forum: authForum.toString()),
  );

  List<Override> get overrides => [
    forumAuthProvider.overrideWith(() => AuthForumController(account)),
    forumBaseUrlProvider.overrideWith(() => AuthBaseController(authForum.toString())),
    workshopClientProvider.overrideWith((ref) async => client),
    workshopPreferencesProvider.overrideWithValue(preferences),
    workshopPrepareDraftProvider.overrideWithValue(drafts.prepare),
    workshopRestoreDraftProvider.overrideWithValue(drafts.restore),
    workshopRequestIdProvider.overrideWithValue(() => (++ids).toRadixString(16).padLeft(32, '0')),
    workshopSourcesLoaderProvider.overrideWithValue(
      () async => WorkshopPublishSources(values: sources, issues: issues),
    ),
    if (publisher case final publisher?) workshopPublishProvider.overrideWith(publisher),
  ];
}

class _Opener extends StatelessWidget {
  const _Opener();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkshopPublishPage())),
        child: const Text('open'),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Lets a brief notice run out, so no timer outlives the test.
Future<void> _clearNotice(WidgetTester tester) => tester.pump(const Duration(seconds: 4));

Future<void> _open(WidgetTester tester, _World world, {Size size = const Size(390, 1800), double textScale = 1}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(goldenApp(home: const _Opener(), brightness: Brightness.light, overrides: world.overrides));
  await tester.tap(find.text('open'));
  await _settle(tester);
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(WorkshopPublishPage)));

/// Nothing on screen may be a stable code or an exception's own text.
void _expectWords(WidgetTester tester) {
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final shown = text.data ?? text.textSpan?.toPlainText() ?? '';
    expect(shown, isNot(contains('workshop_')), reason: 'a code reached the screen: $shown');
    expect(shown, isNot(contains('Exception')), reason: 'an exception reached the screen: $shown');
  }
}

Finder _field(String name) => find.byKey(ValueKey('workshop-publish-$name'));

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
}

/// Picks the pet and fills in what its own defaults leave empty.
Future<void> _fillForm(WidgetTester tester) async {
  await _tapVisible(tester, find.text('Cat'));
  await tester.enterText(_field('title-zh'), '小猫');
  await tester.enterText(_field('id'), 'cat');
  await tester.enterText(_field('author'), 'Author');
  await tester.enterText(_field('source'), 'https://source.example/cat');
  await tester.pump();
  await _tapVisible(tester, find.text('CC0-1.0'));
}

/// From the sources list to the packed result with the rights box ticked.
Future<void> _toReview(WidgetTester tester) async {
  await _fillForm(tester);
  await tester.tap(find.text('下一步'));
  await _settle(tester);
  await _tapVisible(tester, find.byKey(const ValueKey('workshop-publish-rights')));
}

void main() {
  group('gates', () {
    testWidgets('uploads off: says so, and asks for nothing', (tester) async {
      final world = _World(account: const ForumAuthState(phase: ForumAuthPhase.signedOut))..capabilities(uploads: false);
      await _open(tester, world);

      expect(find.text('工坊暂时不接收投稿'), findsOneWidget);
      expect(find.text('登录论坛'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      _expectWords(tester);
    });

    testWidgets('signed out: one line why, and the forum\'s own sign-in', (tester) async {
      final world = _World(account: const ForumAuthState(phase: ForumAuthPhase.signedOut));
      await _open(tester, world);

      expect(find.text('先登录论坛账号'), findsOneWidget);
      expect(find.text('工坊靠论坛账号确认投稿的人是谁。'), findsOneWidget);
      expect(world.preferences.reads, 0);

      await tester.tap(find.text('登录论坛'));
      await _settle(tester);
      // The forum account sheet, not a sign-in of this page's own.
      expect(find.text('发帖、回复、点赞'), findsOneWidget);
    });

    testWidgets('the workshop cannot be reached: the reason in words and a retry', (tester) async {
      final world = _World();
      world.client.readCapabilities = () async => throw const WorkshopException('workshop_network');
      await _open(tester, world);

      expect(find.text('暂时打不开工坊'), findsOneWidget);
      expect(find.text('网络不通，稍后再试。'), findsOneWidget);
      _expectWords(tester);

      world.client.readCapabilities = null;
      await tester.tap(find.text('重试'));
      await _settle(tester);
      expect(find.text('选一个要投稿的'), findsOneWidget);
    });

    testWidgets('no forum profile yet: nothing is read or started', (tester) async {
      final world = _World(account: authSignedIn(userId: null));
      await _open(tester, world);

      expect(find.text('还没读到论坛账号资料'), findsOneWidget);
      expect(world.preferences.reads, 0);
      expect(find.text('选一个要投稿的'), findsNothing);
    });
  });

  group('credential disclosure', () {
    testWidgets('shows both addresses before anything is read or sent', (tester) async {
      final world = _World()..preferences.accepted.clear();
      await _open(tester, world);

      expect(find.text('让工坊核对你的论坛身份'), findsOneWidget);
      expect(find.textContaining('User API Key'), findsOneWidget);
      expect(find.text(authWorker.host), findsOneWidget);
      expect(find.text(authForum.host), findsOneWidget);
      expect(find.text('同意并继续'), findsOneWidget);
      expect(find.text('暂不'), findsOneWidget);
      expect(world.preferences.reads, 0);
      expect(world.preferences.writes, 0);
      expect(world.events, isEmpty);
      _expectWords(tester);
    });

    testWidgets('agreeing saves the pair and only then looks for an unfinished submission', (tester) async {
      final world = _World()..preferences.accepted.clear();
      await _open(tester, world);

      await tester.tap(find.text('同意并继续'));
      await _settle(tester);

      expect(world.preferences.writes, 1);
      expect(world.preferences.accepted, {world.preferences.pair(authWorker, authForum)});
      expect(world.events, ['read-pending']);
      expect(find.text('选一个要投稿的'), findsOneWidget);
    });

    testWidgets('「暂不」 leaves the page and agrees to nothing', (tester) async {
      final world = _World()..preferences.accepted.clear();
      await _open(tester, world);

      await tester.tap(find.text('暂不'));
      await _settle(tester);

      expect(find.byType(WorkshopPublishPage), findsNothing);
      expect(world.preferences.writes, 0);
    });

    testWidgets('a stale confirmation is not taken: the offer is shown again', (tester) async {
      final world = _World()..preferences.accepted.clear();
      await _open(tester, world);

      // The sources are being read again while the old offer is still up.
      final gate = Completer<WorkshopCapabilities>();
      world.client.readCapabilities = () => gate.future;
      final refresh = _container(tester).read(workshopAccessProvider.notifier).refresh();
      await tester.pump();
      await tester.tap(find.text('同意并继续'));
      await tester.pump();

      expect(world.preferences.writes, 0);
      expect(find.text('地址刚刚有变化，请按现在显示的重新确认。'), findsOneWidget);
      expect(find.text('同意并继续'), findsOneWidget);
      _expectWords(tester);

      gate.complete(world.client.value);
      await refresh;
      await _settle(tester);
      expect(find.text('地址刚刚有变化，请按现在显示的重新确认。'), findsNothing);
      await tester.tap(find.text('同意并继续'));
      await _settle(tester);
      expect(world.preferences.writes, 1);
      expect(find.text('选一个要投稿的'), findsOneWidget);
    });

    testWidgets('a consent that could not be saved is said to be for now only', (tester) async {
      final world = _World()..preferences.accepted.clear();
      world.preferences.writeDisclosure = (_, _) async => throw StateError('disk');
      await _open(tester, world);

      await tester.tap(find.text('同意并继续'));
      await _settle(tester);

      expect(find.text('这次同意已经生效，但没能记在本机，下次可能再问一遍。'), findsOneWidget);
      expect(find.text('选一个要投稿的'), findsOneWidget);
      _expectWords(tester);
    });
  });

  group('unfinished submission check', () {
    testWidgets('a record that cannot be read blocks a new submission', (tester) async {
      final world = _World();
      world.preferences.reading = (_) async => throw const WorkshopException('workshop_preferences');
      await _open(tester, world);

      expect(find.text('没能读出上一次投稿的记录'), findsOneWidget);
      expect(find.text('选一个要投稿的'), findsNothing);
      expect(world.preferences.reads, 1, reason: 'asked once, not on every build');
      _expectWords(tester);

      world.preferences.reading = null;
      await tester.tap(find.text('重试'));
      await _settle(tester);
      expect(world.preferences.reads, 2);
      expect(find.text('选一个要投稿的'), findsOneWidget);
    });

    testWidgets('one left from before is shown instead of the form, and continues as the same request', (tester) async {
      final world = _World();
      world.client.creating = (_) async => throw const WorkshopException('workshop_network');
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);
      final first = world.client.creates.single.requestId;

      // The app is opened again: same phone record, new controllers.
      await tester.pumpWidget(const SizedBox.shrink());
      world.client.creating = null;
      await _open(tester, world);

      expect(find.text('有一份投稿还没结束'), findsOneWidget);
      expect(find.text('小猫'), findsOneWidget);
      expect(find.text('选一个要投稿的'), findsNothing);
      expect(find.text('下一步'), findsNothing);
      expect(world.client.creates, hasLength(1), reason: 'restoring sends nothing');

      await tester.tap(find.widgetWithText(FilledButton, '继续投稿'));
      await _settle(tester);
      expect(world.client.creates, hasLength(2));
      expect(world.client.creates.last.requestId, first);
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
    });
  });

  group('source and form', () {
    testWidgets('lists what can be sent, and why something cannot', (tester) async {
      final world = _World()
        ..capabilities(companion: false)
        ..sources = [publishSource, _companion];
      await _open(tester, world);

      expect(find.text('Cat'), findsOneWidget);
      expect(find.text('像素宠物'), findsOneWidget);
      expect(find.text('现在的伙伴'), findsOneWidget);
      expect(find.text('伙伴类作品暂时关闭了。'), findsOneWidget);
      _expectWords(tester);

      await tester.tap(find.text('现在的伙伴'));
      await _settle(tester);
      expect(find.text('下一步'), findsNothing, reason: 'a source the workshop will not take is not picked');
    });

    testWidgets('no companion on the phone is a quiet line, not an error', (tester) async {
      final world = _World()..issues = {'companion': const WorkshopException('workshop_companion_unavailable')};
      await _open(tester, world);

      expect(find.text('本机还没有伙伴，先到伙伴小屋请一位。'), findsOneWidget);
      _expectWords(tester);
    });

    testWidgets('a refused pick is said and nothing changes', (tester) async {
      final world = _World()..publisher = _RefusingPublisher.new;
      await _open(tester, world);

      await tester.tap(find.text('Cat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('上一步还没结束，稍等。'), findsOneWidget);
      expect(find.text('选一个要投稿的'), findsOneWidget);
      expect(find.text('下一步'), findsNothing);
      await _clearNotice(tester);
    });

    testWidgets('field problems are words under the field, and nothing is packed', (tester) async {
      final world = _World();
      await _open(tester, world);
      await tester.tap(find.text('Cat'));
      await _settle(tester);

      // The pet's own name is filled in; the rest is the person's to give.
      expect(tester.widget<TextField>(_field('title-en')).controller!.text, 'Cat');
      expect(tester.widget<TextField>(_field('id')).controller!.text, 'cat');
      await tester.enterText(_field('title-zh'), '');
      await tester.enterText(_field('id'), 'My Cat');
      await tester.enterText(_field('version'), 'one');
      await tester.tap(find.text('下一步'));
      await _settle(tester);

      expect(find.text('名称不能为空，最多 120 个字'), findsOneWidget);
      expect(find.text('只能用小写字母、数字和短横线，最多 40 个字符'), findsOneWidget);
      expect(find.text('写成 1.0.0 这样的版本号'), findsOneWidget);
      expect(find.text('作者不能为空，最多 256 个字'), findsOneWidget);
      expect(find.text('选一个许可'), findsOneWidget);
      expect(find.text('填一个以 https:// 开头的链接'), findsOneWidget);
      expect(world.events, ['read-pending']);
      expect(tester.widget<TextField>(_field('version')).controller!.text, 'one', reason: 'what was typed stays');
      _expectWords(tester);

      // Mending a field takes its line away.
      await tester.enterText(_field('version'), '1.2.0');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('写成 1.0.0 这样的版本号'), findsNothing);
    });

    testWidgets('a line break typed or pasted into the description becomes a space', (tester) async {
      final world = _World();
      await _open(tester, world);
      await _fillForm(tester);
      await tester.enterText(_field('description'), '一只猫\n会打哈欠');
      await tester.pump();
      expect(tester.widget<TextField>(_field('description')).controller!.text, '一只猫 会打哈欠');

      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(world.events, contains('prepare'));
      _expectWords(tester);
    });

    testWidgets('leaving with unsent edits asks first', (tester) async {
      final world = _World();
      await _open(tester, world);
      await tester.tap(find.text('Cat'));
      await _settle(tester);
      await tester.enterText(_field('author'), 'Someone');
      await tester.pump();

      await tester.tap(find.byTooltip('返回'));
      await _settle(tester);
      expect(find.text('放弃修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await _settle(tester);
      expect(find.byType(WorkshopPublishPage), findsOneWidget);

      await tester.tap(find.byTooltip('返回'));
      await _settle(tester);
      await tester.tap(find.text('放弃'));
      await _settle(tester);
      expect(find.byType(WorkshopPublishPage), findsNothing);
    });

    testWidgets('a packing failure stays on the form, in words', (tester) async {
      final world = _World();
      world.drafts.beforeReturn = (_) async => throw const WorkshopException('workshop_storage');
      await _open(tester, world);
      await _fillForm(tester);
      await tester.tap(find.text('下一步'));
      await _settle(tester);

      expect(find.text('没能读写手机上的文件。'), findsOneWidget);
      expect(find.text('下一步'), findsOneWidget);
      expect(world.client.creates, isEmpty);
      _expectWords(tester);
    });
  });

  group('submit', () {
    testWidgets('the packed result is shown, and 「投稿」 needs the rights tick', (tester) async {
      final world = _World();
      await _open(tester, world);
      await _fillForm(tester);
      await tester.tap(find.text('下一步'));
      await _settle(tester);

      expect(world.events, ['read-pending', 'prepare']);
      expect(find.text('小猫'), findsOneWidget);
      expect(find.text('包里的文件'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('我确认自己有权分享这份内容'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);
      expect(find.text('先确认你有权分享这份内容'), findsOneWidget);
      expect(world.client.creates, isEmpty);
      _expectWords(tester);

      await _tapVisible(tester, find.byKey(const ValueKey('workshop-publish-rights')));
      expect(find.text('先确认你有权分享这份内容'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(world.client.creates.single.rights, isTrue);
      expect(world.client.uploads, hasLength(1));
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
      _expectWords(tester);

      await tester.tap(find.text('回到我的投稿'));
      await _settle(tester);
      expect(find.byType(WorkshopPublishPage), findsNothing);

      // Coming back is for sending something else, not for reading it again.
      await tester.tap(find.text('open'));
      await _settle(tester);
      expect(find.text('已交给工坊，等待审核'), findsNothing);
      expect(find.text('选一个要投稿的'), findsOneWidget);
      expect(world.client.creates, hasLength(1));
    });

    testWidgets('「修改资料」 goes back to the form with what was accepted', (tester) async {
      final world = _World();
      await _open(tester, world);
      await _fillForm(tester);
      await tester.tap(find.text('下一步'));
      await _settle(tester);

      await _tapVisible(tester, find.text('修改资料'));
      expect(tester.widget<TextField>(_field('title-zh')).controller!.text, '小猫');
      expect(tester.widget<TextField>(_field('author')).controller!.text, 'Author');

      // Unchanged: the pack is still good, nothing is packed twice.
      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(world.drafts.preparations, 1);
      expect(find.text('包里的文件'), findsOneWidget);

      // Changed: the old pack is not what would be sent.
      await _tapVisible(tester, find.text('修改资料'));
      await tester.enterText(_field('version'), '1.1.0');
      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(world.drafts.preparations, 2);
      expect(find.text('1.1.0'), findsOneWidget);
    });

    testWidgets('a refused rights tick is said and the box stays as it was', (tester) async {
      final world = _World()..publisher = _RefusingTick.new;
      await _open(tester, world);
      await _fillForm(tester);
      await tester.tap(find.text('下一步'));
      await _settle(tester);

      await tester.ensureVisible(find.byKey(const ValueKey('workshop-publish-rights')));
      await tester.tap(find.byKey(const ValueKey('workshop-publish-rights')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('上一步还没结束，稍等。'), findsOneWidget);
      expect(_container(tester).read(workshopPublishProvider).input.rightsConfirmed, isFalse);
      await _clearNotice(tester);
    });

    testWidgets('progress follows the bytes; all bytes sent is still not done', (tester) async {
      final world = _World();
      final answer = Completer<WorkshopSubmission>();
      late PublishUploadCall upload;
      world.client.uploading = (call) {
        upload = call;
        return answer.future;
      };
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await tester.pump();
      await tester.pump();

      upload.progress!(1, 4);
      await tester.pump();
      expect(find.text('正在上传'), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.25);
      expect(find.text('已交给工坊，等待审核'), findsNothing);

      upload.progress!(4, 4);
      await tester.pump();
      expect(find.text('已经传完，等工坊确认…'), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, isNull);
      expect(find.text('已交给工坊，等待审核'), findsNothing);
      expect(find.byType(FilledButton), findsNothing, reason: 'nothing to press while it is being sent');

      answer.complete(publishResult(upload.draft.metadata, id: upload.draft.id, status: WorkshopSubmissionStatus.pending));
      await _settle(tester);
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
    });

    testWidgets('an unknown result is called unknown and only the same request can be asked again', (tester) async {
      final world = _World();
      world.client.creating = (_) async => throw const WorkshopException('workshop_timeout', resultUnknown: true);
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('不确定有没有交上去'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '查看结果'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '投稿'), findsNothing);
      expect(find.byType(FilledButton), findsOneWidget, reason: 'asking again is the only thing offered');
      expect(find.text('下一步'), findsNothing);
      expect(find.text('更换'), findsNothing);
      expect(find.text('重试'), findsNothing);
      _expectWords(tester);

      await tester.tap(find.widgetWithText(FilledButton, '查看结果'));
      await _settle(tester);
      expect(world.client.creates, hasLength(2));
      expect(world.client.creates.last.requestId, world.client.creates.first.requestId);
      expect(world.ids, 1, reason: 'no second request id was ever made');
      expect(find.text('不确定有没有交上去'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重新查询'), findsOneWidget);

      world.client.creating = (call) async =>
          publishResult(call.metadata, status: WorkshopSubmissionStatus.pending);
      await tester.tap(find.widgetWithText(FilledButton, '重新查询'));
      await _settle(tester);
      expect(world.client.creates.last.requestId, world.client.creates.first.requestId);
      expect(world.client.uploads, isEmpty, reason: 'it had arrived: nothing is uploaded twice');
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
    });

    testWidgets('refused before it was sent: the reason, a locked submission, and one way on', (tester) async {
      final world = _World()..sources = [publishSource, _companion];
      world.client.creating = (_) async => throw const WorkshopException('workshop_companion_disabled');
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('有一份投稿还没结束'), findsOneWidget);
      expect(find.text('伙伴类作品暂时关闭了。'), findsOneWidget);
      expect(find.textContaining('暂时不能修改'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '继续投稿'), findsOneWidget);
      expect(find.text('更换'), findsNothing);
      expect(find.text('修改资料'), findsNothing);
      expect(find.text('选一个要投稿的'), findsNothing);
      _expectWords(tester);

      world.client.creating = null;
      await tester.tap(find.widgetWithText(FilledButton, '继续投稿'));
      await _settle(tester);
      expect(world.client.creates.last.requestId, world.client.creates.first.requestId);
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
    });

    testWidgets('known not to have been sent: 「回去修改」 returns to the form with what was typed', (tester) async {
      final world = _World();
      world.client.creating = (_) async =>
          throw const WorkshopException('workshop_upload_disabled', mutationNotSent: true);
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('有一份投稿还没结束'), findsOneWidget);
      expect(find.textContaining('这次还没有发出去'), findsOneWidget);
      expect(find.textContaining('暂时不能修改'), findsNothing);
      expect(find.widgetWithText(FilledButton, '继续投稿'), findsOneWidget);
      _expectWords(tester);

      await _tapVisible(tester, find.text('回去修改'));
      final publish = _container(tester).read(workshopPublishProvider);
      expect(publish.hasPending, isFalse);
      expect(world.client.creates, hasLength(1));
      expect(world.client.uploads, isEmpty);
      // The form again, with the details as they were typed.
      expect(find.text('下一步'), findsOneWidget);
      expect(tester.widget<TextField>(_field('id')).controller!.text, 'cat');
      expect(find.text('有一份投稿还没结束'), findsNothing);
    });

    testWidgets('a rejected one can be sent again, with the tick taken back', (tester) async {
      final world = _World();
      world.client.creating = (call) async =>
          publishResult(call.metadata, status: WorkshopSubmissionStatus.rejected);
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('这份投稿没有通过审核'), findsOneWidget);
      expect(find.text('回到我的投稿'), findsNothing);

      await tester.tap(find.text('重新投稿'));
      await _settle(tester);
      expect(world.events.last, 'retire');
      expect(find.text('下一步'), findsOneWidget);
      expect(tester.widget<TextField>(_field('id')).controller!.text, 'cat', reason: 'the details are kept');
      expect(_container(tester).read(workshopPublishProvider).input.rightsConfirmed, isFalse);
    });

    testWidgets('letting go of the old request failed: 「重试」 tries that step again, and sends nothing', (tester) async {
      final world = _World();
      world.client.creating = (call) async =>
          publishResult(call.metadata, status: WorkshopSubmissionStatus.rejected);
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      world.preferences.retiring = (_, _) async => throw const WorkshopException('workshop_preferences');
      await tester.tap(find.text('重新投稿'));
      await _settle(tester);
      // Still the result, with the record already cleared: what failed is
      // the step after it.
      expect(find.text('这份投稿没有通过审核'), findsOneWidget);
      expect(_container(tester).read(workshopPublishProvider).hasPending, isFalse);
      expect(_container(tester).read(workshopPublishProvider).preferenceError, isNotNull);
      _expectWords(tester);
      await _clearNotice(tester);

      final creates = world.client.creates.length;
      world.preferences.retiring = null;
      await _tapVisible(tester, find.text('重试'));
      expect(world.events.last, 'retire');
      expect(world.client.creates, hasLength(creates));
      expect(_container(tester).read(workshopPublishProvider).preferenceError, isNull);
      expect(find.text('下一步'), findsOneWidget);
    });

    testWidgets('a confirmed result stays a result when the phone record could not be cleared', (tester) async {
      final world = _World();
      world.preferences.clearing = (_, _) async => throw StateError('disk');
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
      expect(find.text('结果已经确认，但本机的投稿记录没能清掉。'), findsOneWidget);
      _expectWords(tester);

      world.preferences.clearing = null;
      await tester.tap(find.text('重试'));
      await _settle(tester);
      expect(world.client.creates, hasLength(1), reason: 'clearing the record sends nothing');
      expect(find.text('结果已经确认，但本机的投稿记录没能清掉。'), findsNothing);
    });
  });

  group('narrow screen, large type', () {
    for (final (name, prepare) in <(String, Future<void> Function(WidgetTester, _World))>[
      ('disclosure', (tester, world) async {}),
      ('form with every error', (tester, world) async {
        await _tapVisible(tester, find.text('Cat'));
        await tester.enterText(_field('title-zh'), '');
        await tester.tap(find.text('下一步'));
        await _settle(tester);
      }),
      ('packed result', (tester, world) async {
        await _fillForm(tester);
        await tester.tap(find.text('下一步'));
        await _settle(tester);
      }),
      ('unknown result', (tester, world) async {
        world.client.creating = (_) async => throw const WorkshopException('workshop_timeout', resultUnknown: true);
        await _toReview(tester);
        await tester.tap(find.widgetWithText(FilledButton, '投稿'));
        await _settle(tester);
      }),
    ]) {
      testWidgets('$name fits 360dp at 1.3×', (tester) async {
        final world = _World();
        if (name == 'disclosure') world.preferences.accepted.clear();
        await _open(tester, world, size: const Size(360, 740), textScale: 1.3);
        await prepare(tester, world);
        expect(tester.takeException(), isNull);
      });
    }
  });
}

/// A publisher that is busy with something else: picks are not accepted.
class _RefusingPublisher extends WorkshopPublishController {
  @override
  bool selectSource(WorkshopPublishSource source) {
    state = state.copyWith(error: const WorkshopException('workshop_busy'));
    return false;
  }
}

/// A publisher that takes the form but not a change of the rights tick.
class _RefusingTick extends WorkshopPublishController {
  @override
  bool setInput(WorkshopPublicationInput input) {
    if (input.rightsConfirmed) {
      state = state.copyWith(error: const WorkshopException('workshop_busy'));
      return false;
    }
    return super.setInput(input);
  }
}
