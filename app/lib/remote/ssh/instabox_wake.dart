import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Compile-time InstaBox wake configuration, supplied by the APK build
/// workflow through `--dart-define`. Empty values disable the feature, so an
/// ordinary build behaves exactly like upstream.
///
/// `INSTABOX_SSH_HOST` is matched against the saved SSH host, so only that one
/// host pays the extra round-trip; every other host connects as before.
const String instaboxWakeSshHost = String.fromEnvironment('INSTABOX_SSH_HOST');
const String instaboxWakeMachineId = String.fromEnvironment('INSTABOX_MACHINE_ID');
const String instaboxWakeApiKey = String.fromEnvironment('INSTABOX_API_KEY');
const String instaboxWakeApiBase = String.fromEnvironment(
  'INSTABOX_API_BASE',
  defaultValue: 'https://api.instabox.sh',
);

/// Whether connecting to [host] should first wake an InstaBox machine.
bool instaboxWakePossibleFor(String host) {
  final wanted = instaboxWakeSshHost.trim().toLowerCase();
  if (wanted.isEmpty || instaboxWakeMachineId.isEmpty || instaboxWakeApiKey.isEmpty) {
    return false;
  }
  return host.trim().toLowerCase() == wanted;
}

class InstaboxWakeError implements Exception {
  InstaboxWakeError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Whether SSH to [host] must offer only the "none" method.
///
/// InstaBox's gateway accepts "none" and only when it is the first method
/// offered: a rejected password attempt makes it refuse every later method.
bool instaboxNoneAuthFor(String host) {
  final wanted = instaboxWakeSshHost.trim().toLowerCase();
  if (wanted.isEmpty) return false;
  return host.trim().toLowerCase() == wanted;
}

/// Wakes the configured InstaBox machine before an SSH connection is opened.
///
/// InstaBox pauses a free machine after 30 idle minutes (and after a maximum
/// run time). A paused machine boots its memory and processes back on resume,
/// so the subsequent SSH connect behaves like a warm machine. An already
/// running machine costs a single `GET` and returns immediately.
class InstaboxWake {
  InstaboxWake._();

  static const Duration _pollInterval = Duration(seconds: 2);

  /// Resolves once the machine reports `running` with `runtime.ready`.
  ///
  /// Throws [InstaboxWakeError] when the API refuses, or when the machine is
  /// not ready within [timeout]. [onProgress] receives short, non-translated
  /// phrases suitable for the connect status line.
  static Future<void> ensureRunning({
    required String host,
    void Function(String detail)? onProgress,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (!instaboxWakePossibleFor(host)) return;

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final deadline = DateTime.now().add(timeout);
      var state = await _readState(client);

      if (_isReady(state)) {
        onProgress?.call('instabox: already running');
        return;
      }

      final action = _wakeActionFor(state['state'] as String?);
      onProgress?.call('instabox: waking machine');
      await _post(client, action);

      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(_pollInterval);
        state = await _readState(client);
        final value = state['state'] as String?;
        if (_isReady(state)) {
          onProgress?.call('instabox: running');
          return;
        }
        if (value == 'error') {
          throw InstaboxWakeError('InstaBox machine entered the error state');
        }
        onProgress?.call('instabox: ' + (value ?? 'unknown'));
      }
      throw InstaboxWakeError(
        'InstaBox machine did not become ready within ' + timeout.inSeconds.toString() + 's',
      );
    } on InstaboxWakeError {
      rethrow;
    } on IOException catch (e) {
      throw InstaboxWakeError('InstaBox API unreachable: ' + e.toString());
    } finally {
      client.close(force: true);
    }
  }

  static bool _isReady(Map<String, dynamic> machine) {
    final runtime = machine['runtime'];
    final ready = runtime is Map ? runtime['ready'] == true : false;
    return machine['state'] == 'running' && ready;
  }

  static String _wakeActionFor(String? state) {
    switch (state) {
      case 'suspended':
        return 'resume';
      case 'running':
        return 'start';
      case 'stopping':
      case 'stopped':
      case 'starting':
      case 'creating':
      case 'resuming':
      case 'suspending':
      default:
        // start is a no-op for a machine already booting and boots a stopped
        // one; the poll loop settles the rest.
        return 'start';
    }
  }

  static Uri _machineUri(String suffix) => Uri.parse(
    instaboxWakeApiBase.replaceAll(RegExp(r'/+$'), '') +
        '/v1/machines/' +
        instaboxWakeMachineId +
        suffix,
  );

  static Map<String, String> _headers({bool idempotent = false}) {
    final headers = <String, String>{
      'X-API-Key': instaboxWakeApiKey,
      'Accept': 'application/json',
    };
    if (idempotent) headers['Idempotency-Key'] = _randomKey();
    return headers;
  }

  static String _randomKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<Map<String, dynamic>> _readState(HttpClient client) async {
    final request = await client.getUrl(_machineUri(''));
    _headers().forEach(request.headers.set);
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode != 200) {
      throw InstaboxWakeError('InstaBox API ' + response.statusCode.toString() + ': ' + body);
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw InstaboxWakeError('Unexpected InstaBox API response');
    }
    return decoded;
  }

  static Future<void> _post(HttpClient client, String action) async {
    final request = await client.postUrl(_machineUri('/' + action));
    _headers(idempotent: true).forEach(request.headers.set);
    request.contentLength = 0;
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode != 202 && response.statusCode != 200 && response.statusCode != 409) {
      throw InstaboxWakeError(
        'InstaBox ' + action + ' failed (' + response.statusCode.toString() + '): ' + body,
      );
    }
  }
}
