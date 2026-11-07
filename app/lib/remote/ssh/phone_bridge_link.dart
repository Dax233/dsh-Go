import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../phone/phone_channel.dart';
import 'remote_shell.dart';
import 'ssh_transport.dart';

/// Carries the phone's MCP bridge to the remote host over one SSH exec channel.
///
/// The gateway refuses `-R`, so the phone opens an exec channel that runs
/// `phone-bridge-host.cjs` on the host. That script listens on a loopback port
/// and multiplexes every accepted connection as JSON frames over its
/// stdout/stdin; this side maps each frame stream to the phone bridge's TCP
/// listener (the `dsh/phone` MCP server).
class PhoneBridgeLink {
  PhoneBridgeLink._(this._exec, this._bridgePort, this._phone);

  final RemoteExecChannel _exec;
  final int _bridgePort;
  final PhoneChannel _phone;
  final Map<int, Socket> _sockets = <int, Socket>{};
  /// Bytes that arrived before the phone-side socket for that id existed.
  final Map<int, List<int>> _pendingData = <int, List<int>>{};
  final Completer<int> _port = Completer<int>();
  final List<int> _pending = <int>[];
  StreamSubscription<Uint8List>? _sub;
  bool _closed = false;

  /// The loopback port the host mux announced (the relay's target).
  int? _announcedPort;

  /// Null until the mux announced its port.
  int? get hostPort => _announcedPort;

  /// Last port published by any link in this process, to notice a change.
  static int? lastPublishedPort;

  /// Starts the link for [transport] when phone control is on; null otherwise.
  static Future<PhoneBridgeLink?> start(SshTransport transport, PhoneChannel phone) async {
    final status = await phone.status().timeout(const Duration(seconds: 2));
    if (!status.ready || !status.enabled) return null;
    final endpoint = await phone.bridgeEndpoint().timeout(const Duration(seconds: 4));
    final port = endpoint?['port'];
    final token = endpoint?['token'];
    if (port is! int || token is! String || token.isEmpty) return null;

    final exec = await transport.execChannel(
      'export PATH=/usr/local/bin:/usr/bin:/bin; exec node ~/.dsh/phone-bridge-host.cjs 0',
    ).timeout(const Duration(seconds: 6));
    final link = PhoneBridgeLink._(exec, port, phone);
    link._listen();
    final int hostPort;
    try {
      hostPort = await link._port.future.timeout(const Duration(seconds: 8));
    } catch (_) {
      await link.close();
      return null;
    }
    final config = jsonEncode(<String, Object>{'host': '127.0.0.1', 'port': hostPort, 'token': token});
    try {
      await transport.run(
        'mkdir -p ~/.dsh && printf %s ${shQuote(config)} > ~/.dsh/phone-bridge.json && chmod 600 ~/.dsh/phone-bridge.json',
        timeout: const Duration(seconds: 20),
      );
    } catch (_) {
      await link.close();
      return null;
    }
    return link;
  }

  void _listen() {
    _sub = _exec.stdout.listen(_onData, onError: (_) => _finish(), onDone: _finish);
  }

  void _onData(Uint8List chunk) {
    _pending.addAll(chunk);
    var newline = _pending.indexOf(10);
    while (newline >= 0) {
      final line = utf8.decode(_pending.sublist(0, newline), allowMalformed: true);
      _pending.removeRange(0, newline + 1);
      _onFrame(line);
      newline = _pending.indexOf(10);
    }
  }

  void _onFrame(String line) {
    if (line.trim().isEmpty) return;
    Map<String, Object?> frame;
    try {
      frame = (jsonDecode(line) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    final kind = frame['t'];
    if (kind == 'listen') {
      final port = frame['port'];
      if (port is int) {
        _announcedPort = port;
        if (!_port.isCompleted) _port.complete(port);
      }
      return;
    }
    final id = frame['id'];
    if (id is! int) return;
    if (kind == 'open') {
      _open(id);
    } else if (kind == 'data') {
      final b = frame['b'];
      if (b is String) {
        final bytes = base64Decode(b);
        final socket = _sockets[id];
        if (socket != null) {
          socket.add(bytes);
        } else {
          // The relay sends its hello line as soon as it connects, which is
          // before this side has finished opening the phone bridge socket.
          _pendingData.putIfAbsent(id, () => <int>[]).addAll(bytes);
        }
      }
    } else if (kind == 'close') {
      _pendingData.remove(id);
      _sockets.remove(id)?.destroy();
    }
  }

  Future<void> _open(int id) async {
    try {
      final socket = await Socket.connect('127.0.0.1', _bridgePort);
      if (_closed) {
        socket.destroy();
        return;
      }
      _sockets[id] = socket;
      final queued = _pendingData.remove(id);
      if (queued != null) socket.add(queued);
      socket.listen(
        (data) => _send(<String, Object>{'t': 'data', 'id': id, 'b': base64Encode(data)}),
        onDone: () => _drop(id),
        onError: (_) => _drop(id),
        cancelOnError: true,
      );
    } catch (_) {
      _send(<String, Object>{'t': 'close', 'id': id});
    }
  }

  void _drop(int id) {
    _sockets.remove(id)?.destroy();
    _send(<String, Object>{'t': 'close', 'id': id});
  }

  void _send(Map<String, Object> frame) {
    if (_closed) return;
    try {
      _exec.stdin.add(Uint8List.fromList(utf8.encode('${jsonEncode(frame)}\n')));
    } catch (_) {
      // The host script is gone; the link closes when its stdout ends.
    }
  }

  Future<void> _finish() async {
    if (_closed) return;
    _closed = true;
    // destroy() can synchronously deliver onDone -> _drop(), which removes from
    // this very map: iterate over a copy (this threw "Concurrent modification
    // during iteration" on every link loss while a bridge was open).
    for (final socket in List<Socket>.of(_sockets.values)) {
      socket.destroy();
    }
    _sockets.clear();
    await _sub?.cancel();
    _sub = null;
  }

  /// Stops the host script and drops every forwarded connection.
  Future<void> close() async {
    await _finish();
    try {
      await _exec.close();
    } catch (_) {
      // Already gone.
    }
    try {
      await _phone.bridgeStopRemote();
    } catch (_) {
      // The native side may be gone; nothing to stop then.
    }
  }
}
