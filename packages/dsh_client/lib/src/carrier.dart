/// Pluggable transport under [DshRpc] and [DshMux].
///
/// A [DshCarrier] moves two kinds of traffic to one Host:
/// * unary Typert Remote calls (`endpoint` + named wire `args`, answered with
///   `{ok, value | error}`), and
/// * physical links ([DshMuxLink]) that multiplex logical streams with the
///   `open / item / end / error / cancel` frame vocabulary of
///   `/api/remote.mux`, including the Gateway-internal `$events` stream.
///
/// [DshMux] owns everything above a single link: the `$events` ready
/// handshake, connection generations, reconnect backoff, reopening streams
/// (resync) and pending approval bookkeeping. A carrier only has to deliver
/// frames for one link and report when that link is gone.
///
/// [DshHttpCarrier] is the default (`POST /api/<endpoint>` +
/// `/api/remote.mux` over a [DshConnection]); `package:dsh_remote` adds an
/// end-to-end encrypted tunnel carrier.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'binary_response.dart';
import 'connection.dart';
import 'errors.dart';
import 'json.dart';
import 'mux.dart';
import 'rpc.dart';
import 'rpc_envelope.dart';

/// Transport for one Host. Implementations must be safe to call
/// concurrently; [DshMux] calls [openLink] again after every link loss.
abstract class DshCarrier {
  /// Short label for diagnostics (`http`, `remote-relay`, ...).
  String get kind;

  /// Release identity freshly associated with the current authenticated link,
  /// if this transport has one. Unknown/disconnected transports return null.
  String? get hostVersion => null;

  /// Optional wire tracer (`bin/probe.dart --record`).
  DshTracer? get tracer;

  /// Whether logical streams accept uplink items and half-close
  /// ([MuxStream.send], [MuxStream.endUplink]).
  bool get supportsUplink => true;

  /// Whether the carrier can reach [endpoint] at all. The local Host serves
  /// every registered endpoint; a remote tunnel only serves a fixed
  /// allow-list. Calls to a refused endpoint resolve to an [RpcError] with
  /// code `METHOD_NOT_ALLOWED` instead of throwing.
  bool allowsEndpoint(String endpoint) => true;

  /// Optional features the far end announced on this link (ds-harness-remote's
  /// encrypted capability probe, e.g. `harness.terminal.v1`). Null when the
  /// carrier has no such probe: [allowsEndpoint] alone decides.
  Set<String>? get peerCapabilities => null;

  /// One unary call. Host failures come back as [RpcError]; carrier
  /// failures throw ([DshHttpException], [DshTransportException],
  /// [DshProtocolException], [DshCarrierRefusedException]).
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout});

  /// Opens a fresh physical link for [DshMux].
  ///
  /// Throw [DshHttpException] 401/403 or [DshCarrierRefusedException] when a
  /// retry cannot succeed without user action (the mux then stops in
  /// [DshConnectionState.unauthorized]); throw any other [DshException] for
  /// transient failures (the mux backs off and retries).
  Future<DshMuxLink> openLink(MuxOptions options);

  /// Releases sockets and clients. Idempotent.
  Future<void> close();
}

/// Downlink callback: `{type: item, streamId, value}`, `{type: end, streamId}`
/// or `{type: error, streamId, error: {code, message, details}}`.
typedef DshMuxFrameHandler = void Function(Map<String, Object?> frame);

/// Link-loss callback. [cause], when set, becomes [DshMux.lastError]
/// (for example a [DshProtocolException] behind the loss).
typedef DshMuxLossHandler = void Function(DshCarrierLostException failure, Object? cause);

/// One physical link carrying logical streams (a WebSocket, or one
/// authenticated tunnel connection).
abstract class DshMuxLink {
  /// Starts delivery. [onLost] fires at most once, when the link dies on its
  /// own; it does not fire for a [close] the mux requested (it may, and the
  /// mux ignores it).
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost});

  /// Opens logical stream [streamId]. [payload] is `{args: {...}}`. A refusal
  /// is reported as an `error` frame for [streamId], never thrown.
  void open(String streamId, String endpoint, Map<String, Object?> payload);

  /// Uplink item; only called when [DshCarrier.supportsUplink].
  void sendItem(String streamId, Object? value);

  /// Uplink half-close; only called when [DshCarrier.supportsUplink].
  void endUplink(String streamId);

  /// Asks the Host to stop [streamId]; late frames for it are ignored.
  void cancel(String streamId);

  /// Closes the link. Codes follow WebSocket conventions (1000 normal,
  /// 4000+ client-defined) and are informational for non-WebSocket links.
  Future<void> close(int code, String reason);
}

/// Counts concurrent unary calls and queues the rest.
///
/// A reconnect makes every provider refill at once — the host trace shows 15
/// unary requests in the same second — and over a slow tunnel that burst is
/// what pushes the next keepalive past its deadline and drops the link again.
/// Four in flight keeps the pipe busy without the pile-up.
class _RpcGate {
  _RpcGate(this.limit);

  final int limit;
  int _active = 0;
  final List<Completer<void>> _waiting = <Completer<void>>[];

  Future<void> enter() {
    if (_active < limit) {
      _active++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future;
  }

  void leave() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _active--;
    }
  }
}

/// The default carrier: unary `POST /api/<endpoint>` and the
/// `/api/remote.mux` WebSocket of a local (or tunnelled) `dsh web`.
class DshHttpCarrier extends DshCarrier {
  DshHttpCarrier(this.connection);

  final DshConnection connection;

  late final _RpcGate? _gate =
      connection.maxConcurrentCalls > 0 ? _RpcGate(connection.maxConcurrentCalls) : null;

  @override
  String get kind => 'http';

  @override
  DshTracer? get tracer => connection.tracer;

  /// Unary call:
  /// ```text
  /// POST /api/session/list            content-type: application/json
  /// {"type":"client-request","rpcId":"<uuid>","method":"session/list",
  ///  "payload":{"args":{"_request":{}}}}
  ///
  /// 200 {"type":"server-response","rpcId":"<uuid>",
  ///      "result":{"ok":true,"value":{...}}}            // value absent for void
  /// 200 {"type":"server-response","rpcId":"<uuid>",
  ///      "result":{"ok":false,"error":{"code","message","details"}}}
  /// ```
  /// Business and gateway failures are HTTP 200 with `ok: false`; only
  /// carrier refusals use HTTP status codes (401 cookie, 403 fence, 404
  /// unclaimed, 415 content type).
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final rpcId = uuidV4();
    final envelope = <String, Object?>{
      'type': 'client-request',
      'rpcId': rpcId,
      'method': endpoint,
      'payload': {'args': args},
    };
    tracer?.call(DshTraceEntry('out', 'rpc', envelope));
    // Without a gate the call must stay synchronous to this point: an
    // `await null` inserts a microtask that changes ordering for callers which
    // depend on the request starting in the current turn.
    final gate = _gate;
    if (gate != null) await gate.enter();
    final DshHttpResponse response;
    try {
      response = await connection.postJson('/api/$endpoint', envelope, timeout: timeout);
    } finally {
      gate?.leave();
    }
    if (response.statusCode != 200) {
      tracer?.call(
        DshTraceEntry('in', 'rpc', {'endpoint': endpoint, 'status': response.statusCode, 'body': response.text}),
      );
      throw DshHttpException(
        response.statusCode,
        httpRpcStatusMessage(response.statusCode, endpoint),
        body: response.text,
      );
    }
    final Map<String, Object?>? decoded;
    if (response.contentType == 'multipart/form-data') {
      // A result with byte attachments (see binary_response.dart).
      final boundary = response.contentTypeParameters.entries
          .where((e) => e.key.toLowerCase() == 'boundary')
          .map((e) => e.value)
          .firstOrNull;
      if (boundary == null || boundary.isEmpty) {
        throw DshProtocolException('$endpoint: multipart result without a boundary');
      }
      decoded = decodeBinaryResponse(response.body, boundary);
    } else {
      decoded = asMap(tryDecodeJson(response.text));
    }
    tracer?.call(
      DshTraceEntry(
        'in',
        'rpc',
        response.contentType == 'multipart/form-data'
            ? {'endpoint': endpoint, 'binaryBytes': response.body.length}
            : {'endpoint': endpoint, 'body': decoded},
      ),
    );
    return readRpcEnvelope(decoded, rpcId, endpoint);
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final socket = await connection.connectWebSocket(remoteMuxPath);
    return _WebSocketMuxLink(socket, tracer, options.pingInterval);
  }

  @override
  Future<void> close() async => connection.close();
}

/// `/api/remote.mux`: one JSON text frame per WebSocket message. The Host
/// pings every 2 s (`dart:io` answers); [pingInterval] adds client pings for
/// dead-link detection.
class _WebSocketMuxLink implements DshMuxLink {
  _WebSocketMuxLink(this._socket, this._tracer, Duration? pingInterval) {
    _socket.pingInterval = pingInterval;
  }

  final WebSocket _socket;
  final DshTracer? _tracer;
  DshMuxLossHandler? _onLost;
  bool _lost = false;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _onLost = onLost;
    _socket.listen(
      (data) {
        if (_lost) return;
        if (data is! String) {
          // A binary frame is not part of this protocol, but one unknown frame
          // must not fail every stream multiplexed over the link: ignore and
          // keep the link. A real protocol break shows up as a missing
          // streamId below.
          _tracer?.call(DshTraceEntry('in', 'mux-binary-ignored', {
            'bytes': data is List<int> ? data.length : null,
          }));
          return;
        }
        final frame = asMap(tryDecodeJson(data));
        final streamId = asString(frame?['streamId']);
        final type = asString(frame?['type']);
        if (frame == null || streamId == null || streamId.isEmpty) {
          _protocolFailure('invalid Remote stream frame');
          return;
        }
        if (type != 'item' && type != 'end' && type != 'error') {
          // A newer Host may add control frames (ack/meta/ping). Ignoring an
          // unknown type is forward compatibility; treating it as a violation
          // would restart every follow stream on the link for nothing.
          _tracer?.call(DshTraceEntry('in', 'mux-unknown-frame', frame));
          return;
        }
        _tracer?.call(DshTraceEntry('in', 'mux', frame));
        onFrame(frame);
      },
      onError: (Object error) => _lose(DshCarrierLostException('WebSocket error: $error'), error),
      onDone: () {
        final failure = DshCarrierLostException(
          'WebSocket closed (${_socket.closeCode ?? 'no code'} ${_socket.closeReason ?? ''})'.trim(),
        );
        _lose(failure, failure);
      },
      cancelOnError: true,
    );
  }

  void _lose(DshCarrierLostException failure, Object? cause) {
    if (_lost) return;
    _lost = true;
    _tracer?.call(
      DshTraceEntry('state', 'carrier-lost', {
        'reason': failure.toString(),
        'closeCode': _socket.closeCode,
        'closeReason': _socket.closeReason,
      }),
    );
    _onLost?.call(failure, cause);
  }

  void _protocolFailure(String reason) {
    _lose(DshCarrierLostException('protocol failure: $reason'), DshProtocolException(reason));
    unawaited(_socket.close(4002, 'invalid Remote stream frame'));
  }

  void _send(Map<String, Object?> frame) {
    _tracer?.call(DshTraceEntry('out', 'mux', frame));
    _socket.add(jsonEncode(frame));
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) =>
      _send({'type': 'open', 'streamId': streamId, 'endpoint': endpoint, 'payload': payload});

  @override
  void sendItem(String streamId, Object? value) => _send({'type': 'item', 'streamId': streamId, 'value': value});

  @override
  void endUplink(String streamId) => _send({'type': 'end', 'streamId': streamId});

  @override
  void cancel(String streamId) => _send({'type': 'cancel', 'streamId': streamId});

  @override
  Future<void> close(int code, String reason) async {
    _lost = true;
    await _socket.close(code, reason);
  }
}
