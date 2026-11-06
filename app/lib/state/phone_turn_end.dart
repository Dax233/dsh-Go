// When phone control is done as a whole: the overlay goes, and the app comes
// back to the conversation so the person reads the result there.
//
// "Done" is the turn's end, not a tool call's: the local engine's
// `api-session/status` falling edge for the conversation, which
// HostAlertTracker (notify/chat_alerts.dart) already turns into turn-end
// alerts. The MCP bridge does not carry a conversation identity. Automatic
// finish is therefore allowed only with one running local conversation in
// that task's initial snapshot; unknown or ambiguous ownership uses the existing
// idle timeout or the person's controls. Looking at a conversation is not
// proof that it owns the phone. When the linked turn ends, the native side
// closes the overlay and, with 「完成后返回 dsh-go」 on and the app in the
// background, brings the app forward on that conversation. Where a vendor
// blocks that, the turn's own notification is the way back
// (an operational phone result, independent of ordinary turn notifications).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notify/chat_alerts.dart';
import '../notify/notify_channel.dart';
import '../l10n/l10n.dart';
import 'app_info.dart';
import 'bots_state.dart';
import 'chat_reveal.dart';
import 'connection_state.dart';
import 'hosts_state.dart' show activeHostProvider;
import 'notify_state.dart' show appForegroundProvider, notifyChannelProvider;
import 'phone_state.dart';

void _trace(String message) {
  if (!kReleaseMode && const bool.fromEnvironment('DSH_PHONE_TURN_TRACE')) {
    debugPrint('DSH_PHONE_TURN $message');
  }
}

/// 设置 → 手机操控 → 「完成后返回 dsh-go」, on by default.
class PhoneReturnPrefController extends Notifier<bool> {
  static const key = 'phone_return_after_done';

  late Future<void> _loaded;

  @override
  bool build() {
    _loaded = _load();
    return true;
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getBool(key);
      if (stored != null && ref.mounted) state = stored;
    } catch (_) {
      // No preferences backend: the default.
    }
  }

  /// Applies after the stored value is in, so a late load can't undo it.
  Future<void> set(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = value;
    try {
      await (await SharedPreferences.getInstance()).setBool(key, value);
    } catch (_) {
      // Kept for this run only.
    }
  }
}

final phoneReturnPrefProvider = NotifierProvider<PhoneReturnPrefController, bool>(PhoneReturnPrefController.new);

/// Which local turn end is the phone task's. Plain Dart (unit-tested).
class PhoneTurnLink {
  int? _taskId;
  bool _armed = false;
  Set<String>? _candidates;
  ({int taskId, String sessionId, Set<String> candidates})? _lastClaim;

  int? get taskId => _taskId;

  /// A phone task ran (or was stopped) and its turn hasn't ended yet.
  bool get armed => _armed;

  /// The conversations it may belong to; null while unknown. Only one is usable.
  Set<String>? get candidates => _candidates;

  /// A status push. True when a new task began: report the conversations
  /// running now with [began].
  bool onStatus(PhoneTaskStatus task) {
    if (task.active) {
      if (task.id == null) return false;
      final fresh = task.id != _taskId;
      if (fresh) {
        _taskId = task.id;
        _armed = true;
        _candidates = null;
        _lastClaim = null;
      }
      return fresh;
    }
    // Over without a stop (minutes idle, engine gone): the overlay went with
    // it and the person has moved on; that turn ending later changes nothing.
    if (!task.stopped && task.id == _taskId) {
      _armed = false;
      _candidates = null;
    }
    return false;
  }

  /// All local conversations running when the task began, including subagents.
  void began(Iterable<String> running) {
    if (!_armed) return;
    _candidates = running.toSet();
  }

  /// Claims an end only for the single captured candidate of this native task.
  bool onTurnEnd(String sessionId) {
    if (!_armed || _taskId == null) return false;
    final c = _candidates;
    if (c == null || c.length != 1 || !c.contains(sessionId)) return false;
    _lastClaim = (taskId: _taskId!, sessionId: sessionId, candidates: c);
    _armed = false;
    _candidates = null;
    return true;
  }

  /// Busy is not evidence that some other conversation owns the task.
  void refused(String sessionId, int taskId) {
    final last = _lastClaim;
    if (last == null || last.sessionId != sessionId || last.taskId != taskId || _taskId != taskId || _armed) return;
    _armed = true;
    _candidates = last.candidates;
  }

  /// The connection or a newer run invalidated the task's ownership evidence.
  void invalidate() {
    _armed = false;
    _candidates = null;
    _lastClaim = null;
  }
}

class _OwnerRead {
  _OwnerRead(this.taskId, this.client, this.generation, this.lifetime);
  final int taskId;
  final DshClient client;
  final MuxGeneration? generation;
  final Object lifetime;
  bool valid = true;
  StreamSubscription<DshConnectionState>? mux;
  StreamSubscription<HostEvent>? events;

  void retire() {
    valid = false;
    unawaited(mux?.cancel());
    unawaited(events?.cancel());
  }
}

class _DeferredPhoneEnd {
  _DeferredPhoneEnd(this.read, this.ready);
  final _OwnerRead read;
  final void Function() ready;
  Timer? timer;
}

/// Watches the phone task and ends it with its turn ([onTurnEnd], called by
/// ChatAlertsController for every local turn end). Kept alive with
/// [phoneStopWatcherProvider] by the home shell, so it has seen the task begin.
class PhoneTurnEndController extends Notifier<void> {
  final link = PhoneTurnLink();
  Object _lifetime = Object();
  _OwnerRead? _reading;
  DshClient? _ownerClient;
  MuxGeneration? _ownerGeneration;
  final _deferred = <String, _DeferredPhoneEnd>{};

  static const ownerWait = Duration(seconds: 5);
  static const maxDeferredEnds = 8;

  @override
  void build() {
    final lifetime = _lifetime = Object();
    final channel = ref.watch(phoneChannelProvider);
    ref.listen(activeConnectionProvider, (before, after) {
      final old = before?.value?.client;
      final next = after.value?.client;
      if (old != null && !identical(old, next)) {
        link.invalidate();
        final reading = _reading;
        if (reading != null) _retireRead(reading);
        _ownerClient = null;
        _ownerGeneration = null;
      }
      if (link.armed &&
          link.candidates == null &&
          after.value?.client != null &&
          !identical(before?.value?.client, after.value?.client)) {
        unawaited(_snapshot(link.taskId!));
      }
    });
    StreamSubscription<PhoneStatus>? sub;
    var disposed = false;
    ref.onDispose(() {
      disposed = true;
      if (identical(_lifetime, lifetime)) {
        _lifetime = Object();
        _reading?.retire();
        _reading = null;
        for (final pending in _deferred.values) {
          pending.timer?.cancel();
        }
        _deferred.clear();
        link.invalidate();
      }
      unawaited(sub?.cancel());
    });
    unawaited(() async {
      try {
        final status = await channel.status();
        // No native side (tests, an older build): nothing to watch.
        if (disposed || !status.ready) return;
        _onStatus(status);
        sub = channel.statusChanges.listen((status) {
          if (!disposed) _onStatus(status);
        }, onError: (_) {});
      } catch (_) {
        // No platform channels at all (plain unit tests).
      }
    }());
  }

  void _onStatus(PhoneStatus status) {
    _trace(
      'task=${status.task.id} event=status active=${status.task.active} stopped=${status.task.stopped} paused=${status.task.paused}',
    );
    if (link.onStatus(status.task)) {
      final reading = _reading;
      if (reading != null) _retireRead(reading, invalidate: false);
      _ownerClient = null;
      _ownerGeneration = null;
      _trace('task=${link.taskId} event=begin');
      unawaited(_snapshot(link.taskId!));
    } else if (!link.armed) {
      final reading = _reading;
      if (reading != null) _retireRead(reading, invalidate: false);
    }
  }

  bool _currentRead(_OwnerRead read) =>
      ref.mounted &&
      read.valid &&
      identical(_lifetime, read.lifetime) &&
      identical(_reading, read) &&
      link.armed &&
      link.taskId == read.taskId &&
      identical(ref.read(activeConnectionProvider).value?.client, read.client) &&
      identical(read.client.mux.generation, read.generation);

  void _settleDeferred(_OwnerRead read, {required bool resume}) {
    final keys = [
      for (final e in _deferred.entries)
        if (identical(e.value.read, read)) e.key,
    ];
    for (final key in keys) {
      final pending = _deferred.remove(key)!;
      pending.timer?.cancel();
      if (resume && ref.mounted && identical(_lifetime, read.lifetime)) pending.ready();
    }
  }

  void _retireRead(_OwnerRead read, {bool invalidate = true}) {
    read.retire();
    if (identical(_reading, read)) {
      _reading = null;
      if (invalidate) link.invalidate();
    }
    // New runs, tasks and connections revoke the end itself. Replaying it as
    // an ordinary notification would revive the UI after ownership was lost.
    _settleDeferred(read, resume: false);
  }

  Future<void> _snapshot(int taskId) async {
    final scope = ref;
    final client = scope.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final previous = _reading;
    if (previous != null && previous.taskId == taskId && identical(previous.client, client)) return;
    final read = _reading = _OwnerRead(taskId, client, client.mux.generation, _lifetime);
    read.mux = client.mux.states.listen((_) {
      if (read.valid) _retireRead(read);
    });
    read.events = client.hostEvents.listen((event) {
      if (event is SessionStatusEvent && event.running && _deferred.containsKey(event.sessionId)) {
        // A later run must never be finished using the earlier end and snapshot.
        if (read.valid) _retireRead(read);
      }
    });
    try {
      final sessions = await client.listSessions().timeout(ownerWait);
      if (!_currentRead(read)) return;
      _ownerClient = client;
      _ownerGeneration = read.generation;
      link.began([
        for (final s in sessions)
          if (s.running) s.sessionId,
      ]);
      _trace('task=$taskId event=snapshot candidates=${link.candidates?.length}');
    } catch (_) {
      _trace('task=$taskId event=snapshot-unavailable');
    } finally {
      // Success, ambiguity and a failed/timed-out read may resume normal
      // notification handling only while the original task scope is current.
      final resume = _currentRead(read);
      read.retire();
      if (identical(_reading, read)) _reading = null;
      _settleDeferred(read, resume: resume);
    }
  }

  /// Holds a turn alert only while this task's initial owner read is in flight.
  /// The caller retries once with this hook disabled; timeout/ambiguity must not
  /// requeue forever or turn the currently viewed conversation into proof.
  bool deferTurnEnd(ChatAlert alert, void Function() ready) {
    final read = _reading;
    // The task belongs to the Host that was active when control began: with a
    // remote engine (the usual setup here) that is not the local one, and
    // gating on isLocal left a remote-driven task running after its turn ended.
    if (alert.host != ref.read(activeHostProvider) ||
        alert.key != turnKey ||
        alert.turnEndKind == null ||
        !link.armed ||
        link.candidates != null ||
        read == null ||
        !read.valid ||
        read.taskId != link.taskId ||
        !identical(read.lifetime, _lifetime)) {
      return false;
    }
    if (_deferred.containsKey(alert.sessionId)) return true;
    if (_deferred.length >= maxDeferredEnds) return false;
    final pending = _DeferredPhoneEnd(read, ready);
    _deferred[alert.sessionId] = pending;
    pending.timer = Timer(ownerWait, () {
      if (!identical(_deferred[alert.sessionId], pending)) return;
      _deferred.remove(alert.sessionId);
      if (_currentRead(read)) ready();
    });
    return true;
  }

  /// [alert] is a turn end on some host. Null unless it is the phone task's;
  /// then the overlay is closing (and the app maybe coming back to that
  /// conversation) and the future says how it went.
  Future<PhoneFinish>? onTurnEnd(ChatAlert alert) {
    // A remote Host drives the phone just as well as the local engine; the
    // owner read below uses the active connection, so the gate is "same host",
    // not "local host".
    if (alert.host != ref.read(activeHostProvider) || alert.key != turnKey || alert.turnEndKind == null) {
      return null;
    }
    final scope = ref;
    final lifetime = _lifetime;
    final client = scope.read(activeConnectionProvider).value?.client;
    final generation = client?.mux.generation;
    if (link.candidates != null &&
        (!identical(client, _ownerClient) || !identical(client?.mux.generation, _ownerGeneration))) {
      link.invalidate();
      return null;
    }
    final candidates = link.candidates?.length;
    if (link.armed) _trace('task=${link.taskId} event=end kind=${alert.kind.name} candidates=$candidates');
    if (!link.onTurnEnd(alert.sessionId)) {
      if (link.armed) _trace('task=${link.taskId} event=end-ignored candidates=$candidates');
      return null;
    }
    final taskId = link.taskId!;
    final reopen = ref.read(phoneReturnPrefProvider) && !ref.read(appForegroundProvider);
    // DS Bot's conversations live in their room, not the chat: just the app.
    final bot = ref.read(dsBotSessionFilterProvider)(alert.host, alert.sessionId);
    final channel = ref.read(phoneChannelProvider);
    return () async {
      final result = await channel.finishTask(
        taskId: taskId,
        sessionId: bot ? null : alert.sessionId,
        host: alert.host.encode(),
        reopen: reopen,
      );
      _trace(
        'task=$taskId event=finish closed=${result.closed} busy=${result.busy} opened=${result.opened} launched=${result.launched}',
      );
      if (!scope.mounted ||
          !identical(_lifetime, lifetime) ||
          link.taskId != taskId ||
          !result.current ||
          !identical(scope.read(activeConnectionProvider).value?.client, client) ||
          !identical(client?.mux.generation, generation)) {
        return result.retired();
      }
      if (result.busy) link.refused(alert.sessionId, taskId);
      if (result.opened && result.launched && !bot && ref.mounted && link.taskId == taskId) {
        ref.read(chatRevealProvider.notifier).reveal(alert.sessionId);
      }
      if (result.closed && reopen && !result.opened && !result.notified && !bot && !scope.read(appForegroundProvider)) {
        // Return is an explicit phone-control preference. This operational
        // fallback also works with ordinary chat turn notifications off.
        final notified = await scope
            .read(notifyChannelProvider)
            .tryShow(
              NotifyPost(
                group: notifyGroup(alert.host, alert.sessionId),
                key: 'phone-$taskId',
                attention: true,
                title: AppInfo.name,
                text: alert.kind == AlertKind.done ? appL10n.phoneTaskResultReady : appL10n.phoneTaskEndedResult,
                publicText: appL10n.phoneTaskEndedResult,
                sessionId: alert.sessionId,
                host: alert.host,
                kind: 'phone-result',
              ),
              stillCurrent: () =>
                  scope.mounted &&
                  identical(_lifetime, lifetime) &&
                  link.taskId == taskId &&
                  !scope.read(appForegroundProvider) &&
                  identical(scope.read(activeConnectionProvider).value?.client, client) &&
                  identical(client?.mux.generation, generation),
            );
        if (notified) return result.withNotice();
      }
      return result;
    }();
  }
}

final phoneTurnEndProvider = NotifierProvider<PhoneTurnEndController, void>(PhoneTurnEndController.new);
