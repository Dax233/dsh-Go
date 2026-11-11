import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";

import "instabox_wake.dart";

/// Fixed-size, content-free record of what the keeper last did. Diagnostics
/// reads it; nothing here carries a key, a payload or a path.
class InstaboxActivityLog {
  InstaboxActivityLog._();

  static const int _limit = 24;
  static final List<Map<String, Object?>> _entries = <Map<String, Object?>>[];

  static void add(String kind, {required bool ok, Object? detail}) {
    _entries.add({
      "at": DateTime.now().toUtc().toIso8601String(),
      "kind": kind,
      "ok": ok,
      if (detail != null) "detail": "$detail",
    });
    if (_entries.length > _limit) _entries.removeRange(0, _entries.length - _limit);
  }

  static List<Map<String, Object?>> get entries => List.unmodifiable(_entries);

  static int _ok(String kind) =>
      _entries.where((e) => e["kind"] == kind && e["ok"] == true).length;

  static int _failed(String kind) =>
      _entries.where((e) => e["kind"] == kind && e["ok"] != true).length;

  static var _running = false;
  static String? _host;
  static Map<String, Object?> _machine = const {};

  /// The link marks the keeper live so the diagnostics snapshot needs no access
  /// to the link itself.
  static void markRunning({required bool running, String? host}) {
    _running = running;
    _host = running ? host : null;
  }

  /// Last machine facts: state, ready, and how much of the maximum runtime is
  /// left. Null fields are omitted so a paused machine does not look running.
  static void setMachine(Map<String, Object?> facts) => _machine = facts;

  static Map<String, Object?> snapshot() => {
    "configured": instaboxActivityConfigured,
    "host": _host,
    "running": _running,
    "leasesOk": _ok("lease"),
    "leasesFailed": _failed("lease"),
    "workOk": _ok("exec"),
    "workFailed": _failed("exec"),
    ..._machine,
    "recent": entries,
  };
}

/// Whether the build carries an InstaBox machine id and key at all.
bool get instaboxActivityConfigured =>
    instaboxWakeMachineId.isNotEmpty && instaboxWakeApiKey.isNotEmpty;

/// Keeps the configured InstaBox machine busy while a link to it is open.
///
/// The platform decides "idle" on the host side: an activity lease is the
/// sanctioned way to say "a silent task is still working", and a tiny exec
/// every few minutes is a real unit of work when the runtime check looks for
/// working minutes. Neither extends the 480-minute maximum runtime.
class InstaboxActivityKeeper {
  InstaboxActivityKeeper({
    this.leaseTtl = const Duration(seconds: 600),
    this.renewEvery = const Duration(seconds: 180),
    this.workEvery = const Duration(minutes: 10),
    this.stateEvery = const Duration(minutes: 5),
    this.requestTimeout = const Duration(seconds: 20),
    String? taskId,
  }) : taskId = taskId ?? "dsh-go-${_token()}";

  /// The lease is renewed well before it expires, so one slow round-trip does
  /// not let the machine look idle.
  final Duration leaseTtl;
  final Duration renewEvery;

  /// One cheap `true` counts as real work; the interval keeps the machine from
  /// looking like a probe that only exists to stay alive.
  final Duration workEvery;
  final Duration requestTimeout;
  final String taskId;

  /// The machine's own state and remaining maximum runtime are read from the
  /// stored machine record (a read, not a wake), so a countdown can be shown
  /// before the platform pauses the run.
  final Duration stateEvery;

  Timer? _renewTimer;
  Timer? _workTimer;
  Timer? _stateTimer;
  var _disposed = false;

  static String _token() {
    final random = Random.secure();
    return List<int>.generate(6, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, "0"))
        .join();
  }

  String get _base => instaboxWakeApiBase.replaceAll(RegExp(r"/+$"), "");

  Uri _leaseUri() => Uri.parse(
      "$_base/v1/machines/$instaboxWakeMachineId/activity-leases/$taskId");

  Uri _execUri() =>
      Uri.parse("$_base/v1/machines/$instaboxWakeMachineId/exec");

  Map<String, String> get _headers => {
    "X-API-Key": instaboxWakeApiKey,
    "Accept": "application/json",
    "Content-Type": "application/json",
  };

  /// Starts renewing at once: a link that just came up is usually the moment
  /// the machine begins a silent stretch.
  Future<void> start() async {
    if (_disposed || !instaboxActivityConfigured) return;
    await _lease();
    unawaited(_state());
    _renewTimer = Timer.periodic(renewEvery, (_) => unawaited(_lease()));
    _workTimer = Timer.periodic(workEvery, (_) => unawaited(_work()));
    _stateTimer = Timer.periodic(stateEvery, (_) => unawaited(_state()));
  }

  /// Releases the lease on a clean disconnect; a crash simply lets the TTL run
  /// out, which is why the TTL stays short.
  Future<void> stop() async {
    if (_disposed) return;
    _disposed = true;
    _renewTimer?.cancel();
    _workTimer?.cancel();
    _stateTimer?.cancel();
    _renewTimer = null;
    _workTimer = null;
    _stateTimer = null;
    if (!instaboxActivityConfigured) return;
    try {
      await _send("DELETE", _leaseUri()).timeout(requestTimeout);
      InstaboxActivityLog.add("release", ok: true);
    } catch (e) {
      InstaboxActivityLog.add("release", ok: false, detail: e);
    }
  }

  Future<void> _lease() async {
    if (_disposed || !instaboxActivityConfigured) return;
    try {
      final status = await _send("PUT", _leaseUri(),
              body: jsonEncode({"ttlSeconds": leaseTtl.inSeconds}))
          .timeout(requestTimeout);
      final ok = status >= 200 && status < 300;
      InstaboxActivityLog.add("lease", ok: ok, detail: ok ? null : "http $status");
    } catch (e) {
      InstaboxActivityLog.add("lease", ok: false, detail: e);
    }
  }

  Future<void> _work() async {
    if (_disposed || !instaboxActivityConfigured) return;
    try {
      final status = await _send("POST", _execUri(),
              body: jsonEncode({"cmd": "true", "timeoutSeconds": 30}))
          .timeout(requestTimeout);
      final ok = status >= 200 && status < 300;
      InstaboxActivityLog.add("exec", ok: ok, detail: ok ? null : "http $status");
    } catch (e) {
      InstaboxActivityLog.add("exec", ok: false, detail: e);
    }
  }

  /// Reads the stored machine record: state, runtime readiness, and the
  /// maximum-runtime clock. This is a read (does not wake), used only for a
  /// countdown and for attributing a later pause.
  Future<void> _state() async {
    if (_disposed || !instaboxActivityConfigured) return;
    try {
      final body = await _sendForBody("GET", _machineUri()).timeout(requestTimeout);
      final map = (jsonDecode(body) as Map<dynamic, dynamic>).cast<String, dynamic>();
      final runtime = map["runtime"] is Map
          ? (map["runtime"] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      final started = DateTime.tryParse("${map["runStartedAt"] ?? ""}");
      final maxRun = map["maxRunMinutes"];
      int? remaining;
      if (started != null && maxRun is int && maxRun > 0) {
        remaining = maxRun - DateTime.now().toUtc().difference(started).inMinutes;
        if (remaining < 0) remaining = 0;
      }
      InstaboxActivityLog.setMachine({
        "machineState": map["state"],
        "ready": runtime["ready"] == true,
        "maxRunMinutes": ?maxRun,
        "runStartedAt": ?map["runStartedAt"],
        "remainingMinutes": ?remaining,
      });
      InstaboxActivityLog.add("state",
          ok: true,
          detail: "state=${map["state"]}${remaining != null ? " remaining=${remaining}m" : ""}");
    } catch (e) {
      InstaboxActivityLog.add("state", ok: false, detail: e);
    }
  }

  Uri _machineUri() =>
      Uri.parse("$_base/v1/machines/$instaboxWakeMachineId");

  Future<String> _sendForBody(String method, Uri uri) async {
    final client = HttpClient()..connectionTimeout = requestTimeout;
    try {
      final request = await client.openUrl(method, uri);
      _headers.forEach(request.headers.set);
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError("http ${response.statusCode}");
      }
      return text;
    } finally {
      client.close(force: true);
    }
  }

  Future<int> _send(String method, Uri uri, {String? body}) async {
    final client = HttpClient()..connectionTimeout = requestTimeout;
    try {
      final request = await client.openUrl(method, uri);
      _headers.forEach(request.headers.set);
      if (body != null) {
        final bytes = utf8.encode(body);
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }
}
