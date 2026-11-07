import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../../state/link_loss_log.dart';
import '../link_status.dart';
import 'instabox_wake.dart';
import '../../phone/phone_channel.dart';
import 'local_forward.dart';
import 'phone_bridge_link.dart';
import 'remote_bootstrap.dart';
import 'remote_shell.dart';
import 'ssh_host_config.dart';
import 'ssh_transport.dart';

/// What the person is asked on first contact with a host.
class HostKeyPrompt {
  const HostKeyPrompt({required this.hostName, required this.address, required this.key});

  final String hostName;
  final String address;
  final PresentedHostKey key;
}

/// Shows the "trust this host?" question; true to pin and continue.
typedef HostKeyPrompter = Future<bool> Function(HostKeyPrompt prompt);

/// Persists a newly trusted key for the host.
typedef HostKeyPinner = Future<void> Function(PresentedHostKey key);

/// Logs in to the `dsh web` behind the tunnel.
typedef DshClientConnector = Future<DshClient> Function({
  required Uri baseUri,
  required String token,
  required String hostHeader,
});

/// Diagnostics sink for mux/carrier state changes (installed by the host link).
void Function(DshTraceEntry entry)? dshLinkTrace;

Future<DshClient> _defaultConnector({required Uri baseUri, required String token, required String hostHeader}) =>
    DshClient.connect(
      baseUri: baseUri,
      token: token,
      hostHeader: hostHeader,
      tracer: (entry) => dshLinkTrace?.call(entry),
      // The SSH link carries this mux, so the SSH keepalive is the physical
      // liveness check. dart:io's WebSocket ping timer would close a healthy
      // socket with 1001 whenever a pong is merely late across the tunnel.
      // 80 ms between the stream opens that follow a reconnect: five streams
      // opening at once is what re-breaks a slow link.
      muxOptions: const MuxOptions(pingInterval: null, reopenStagger: Duration(milliseconds: 80)),
      // A reconnect refills every provider at once; four unary calls in flight
      // keeps the slow tunnel busy without the pile-up that starves the
      // keepalive and drops the link straight back.
      maxConcurrentCalls: 4,
    );

/// Trust-on-first-use check against the pinned fingerprint.
enum HostKeyVerdict { trusted, unknown, mismatch }

HostKeyVerdict checkHostKey(SshHostConfig config, PresentedHostKey key) {
  final pinned = config.hostKeyFingerprint;
  if (pinned == null || pinned.isEmpty) return HostKeyVerdict.unknown;
  return pinned == key.fingerprint ? HostKeyVerdict.trusted : HostKeyVerdict.mismatch;
}

HostLinkError hostKeyMismatchError(SshHostConfig config, PresentedHostKey key) => HostLinkError(
  HostLinkErrorKind.hostKeyMismatch,
  appL10n.remoteErrFingerprintChanged,
  detail: appL10n.remoteHostKeyMismatchDetail(config.hostKeyFingerprint.toString(), key.fingerprint, key.shortType),
);

/// SSH remote host: connect → verify host key → start/reuse `dsh web` →
/// local forward → DshClient login; then keepalive and reconnect.
///
/// Mirrors dsh-tauri's SSH plugin flow (`bootstrap.utils.ts`, `transport.ts`):
/// the remote server binds 127.0.0.1 only, the token comes from its log, and
/// the client presents `Host: 127.0.0.1:<remote port>` so DSH's Host fence
/// accepts requests that arrive through the tunnel.
/// Generated profile for remote phone control: a copy of `web` plus the
/// `mcp-phone` MCP client. __RELAY_PATH__ becomes the absolute relay path.
const String _phoneProfileScript = r'''
set -e
D="$HOME/.dsh/profiles"
mkdir -p "$D/web-phone"
for f in package.json pnpm-workspace.yaml cordis.yml cordis.patch.yml; do
  if [ -f "$D/web/$f" ]; then cp -a "$D/web/$f" "$D/web-phone/$f"; fi
done
ln -sfn ../web/node_modules "$D/web-phone/node_modules"
if ! grep -q 'id: mcp-phone' "$D/web-phone/cordis.patch.yml"; then
  cat >> "$D/web-phone/cordis.patch.yml" <<'PHONEYAML'
- insert:
    - id: mcp-phone
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: phone
        transport: stdio
        command: node
        args: ['__RELAY_PATH__']
        toolCallTimeoutMs: 120000
PHONEYAML
fi
''';
class SshHostLink implements HostLink {
  SshHostLink({
    required this._config,
    required this._loadSecrets,
    this.promptHostKey,
    this.pinHostKey,
    SshTransportFactory? transportFactory,
    DshClientConnector? connectClient,
    Stream<void>? kicks,
    Backoff? backoff,
    this.remoteEnvironment = const {},
    this.keepAliveInterval = const Duration(seconds: 20),
    this.keepAliveTimeout = const Duration(seconds: 30),
    this.muxProbeDelay = const Duration(seconds: 30),
    this.tunnelProbeTimeout = const Duration(seconds: 10),
    this.retryFirstOpen = true,
  }) : _transportFactory = transportFactory ?? DartSshTransport.connect,
       _connectClient = connectClient ?? _defaultConnector,
       _backoff = backoff ?? Backoff() {
    _kickSub = kicks?.listen((_) => kick());
  }

  SshHostConfig _config;
  final Future<SshSecrets> Function() _loadSecrets;
  final HostKeyPrompter? promptHostKey;
  final HostKeyPinner? pinHostKey;
  final SshTransportFactory _transportFactory;
  final DshClientConnector _connectClient;
  final Backoff _backoff;
  final Map<String, String> remoteEnvironment;
  final Duration keepAliveInterval;
  final Duration keepAliveTimeout;

  /// How long the mux may stay disconnected before the DSH port is probed.
  ///
  /// The Host recycles idle mux sockets as a matter of course; that reconnect
  /// is not evidence that the DSH process died. Probing it immediately used to
  /// turn one ordinary socket recycle into a full SSH reconnect (new phone
  /// bridge port, every stream torn down), several times a minute.
  final Duration muxProbeDelay;

  /// Bounds the initial probe and subsequent forwarded channel opens.
  final Duration tunnelProbeTimeout;

  /// False for "测试连接": report the first failure instead of retrying.
  final bool retryFirstOpen;

  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  final _delay = InterruptibleDelay();
  StreamSubscription<void>? _kickSub;
  StreamSubscription<DshConnectionState>? _muxSub;
  HostLinkStatus _status = HostLinkStatus.idle;

  SshTransport? _transport;
  SshTransport? _connectingTransport;
  Completer<SshTransport> _ready = Completer<SshTransport>();
  LocalForwarder? _forwarder;
  RemoteDshEndpoint? _endpoint;
  DshClient? _client;
  Future<DshClient>? _opening;
  Future<DshClient>? _connecting;
  Timer? _keepAlive;
  bool _keepAliveTickInFlight = false;
  int _missedPings = 0;

  /// When the mux first stopped being connected, or null while it is
  /// connected. A sustained outage - not one reconnect - may touch DSH.
  DateTime? _muxDownSince;
  /// Upper bound on one SSH global keepalive request. The channel round-trip
  /// that follows it gets the caller's whole budget instead.
  static const Duration _pingRequestTimeout = Duration(seconds: 8);

  bool _closed = false;
  bool _recovering = false;
  bool _needsRelogin = false;
  bool _forceRestart = false;

  SshHostConfig get config => _config;

  /// Takes a rename, a new working directory or a re-pinned key without
  /// touching the SSH session (a new address or login needs a new link).
  void updateConfig(SshHostConfig next) {
    _config = _config.copyWith(
      name: next.name,
      workingDirectory: () => next.workingDirectory,
      hostKeyType: () => next.hostKeyType,
      hostKeyFingerprint: () => next.hostKeyFingerprint,
    );
  }

  RemoteDshEndpoint? get endpoint => _endpoint;

  /// The local forward port (null before the first tunnel).
  int? get localPort => _forwarder?.port;

  /// Configured working directory with `~` resolved on the remote.
  String? get resolvedWorkingDirectory => RemoteDshBootstrap.absolutePath(_config.workingDirectory, _endpoint?.home);

  @override
  HostLinkStatus get status => _status;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  Stream<DshClient> get clients => _clients.stream;

  void _emit(HostLinkStatus next) {
    if (_closed && next.phase != HostLinkPhase.idle) return;
    _status = next;
    _statuses.add(next);
  }

  @override
  Future<DshClient> open() {
    if (_closed) return Future.error(StateError('link closed'));
    final client = _client;
    if (client != null && _status.isConnected) return Future.value(client);
    return _opening ??= _openFirst().whenComplete(() => _opening = null);
  }

  /// One SSH connect at a time.
  ///
  /// `open()` and the recovery loop can both want a connection (a network kick
  /// while the screen opens, say). Two parallel attempts each build their own
  /// transport and client, and the later one replaces — then closes — the
  /// first, which the Host sees as two WebSocket upgrades followed by a close.
  Future<DshClient> _connectGuarded() => _connecting ??= _connectOnce().whenComplete(() => _connecting = null);

  Future<DshClient> _openFirst() async {
    _backoff.reset();
    _emit(const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    try {
      return await _connectGuarded();
    } on HostLinkError catch (e) {
      if (!e.retryable || !retryFirstOpen) {
        _fail(e);
        rethrow;
      }
      return _recover(e);
    } catch (e) {
      final error = HostLinkError(
        HostLinkErrorKind.other,
        appL10n.commonConnectionFailed,
        detail: '$e',
        retryable: true,
      );
      if (!retryFirstOpen) {
        _fail(error);
        throw error;
      }
      return _recover(error);
    }
  }

  void _fail(HostLinkError error) {
    _teardownTransport();
    _emit(HostLinkStatus(HostLinkPhase.failed, step: _status.step, completed: _status.completed, error: error));
  }

  void _checkOpen() {
    if (_closed) throw StateError('link closed');
  }

  /// One full attempt. Reuses the forwarder and, when the remote endpoint is
  /// unchanged, the existing DshClient.
  Future<DshClient> _connectOnce() async {
    var step = _status.withStep(HostLinkStep.connect);
    void at(HostLinkStep s, {String? detail}) {
      step = step.withStep(s, detail: detail);
      _emit(step);
    }

    at(HostLinkStep.connect, detail: _config.address);
    // A locked keystore can leave this read pending indefinitely; the connect
    // attempt must fail (and retry) instead of sitting at "连接服务器…".
    final secrets = await _loadSecrets().timeout(const Duration(seconds: 30));
    _checkOpen();

    // InstaBox machines pause when idle; wake ours before the socket is opened.
    if (instaboxWakePossibleFor(_config.host)) {
      at(HostLinkStep.connect, detail: 'instabox: waking');
      await InstaboxWake.ensureRunning(
        host: _config.host,
        onProgress: (detail) => at(HostLinkStep.connect, detail: detail),
      );
      _checkOpen();
    }
    final transport = await _transportFactory(SshConnectParams.of(_config, secrets), (key) async {
      if (_closed) return false;
      at(HostLinkStep.verifyHostKey, detail: '${key.shortType} ${key.fingerprint}');
      switch (checkHostKey(_config, key)) {
        case HostKeyVerdict.trusted:
          return true;
        case HostKeyVerdict.mismatch:
          throw hostKeyMismatchError(_config, key);
        case HostKeyVerdict.unknown:
          final prompt = promptHostKey;
          if (prompt == null) {
            throw HostLinkError(
              HostLinkErrorKind.hostKeyUnverified,
              appL10n.remoteErrFingerprintUnconfirmed,
              detail: '${key.shortType} ${key.fingerprint}',
            );
          }
          final ok = await prompt(HostKeyPrompt(hostName: _config.name, address: _config.address, key: key));
          if (_closed) return false;
          if (!ok) {
            throw HostLinkError(HostLinkErrorKind.hostKeyRejected, appL10n.remoteHostTrustCancelled);
          }
          _config = _config.copyWith(hostKeyType: () => key.type, hostKeyFingerprint: () => key.fingerprint);
          await pinHostKey?.call(key);
          if (_closed) return false;
          return true;
      }
    });
    if (_closed) {
      transport.close();
      throw StateError('link closed');
    }
    // Own the authenticated connection while bootstrap/probe are pending.
    _connectingTransport = transport;
    await _bridgeBreadcrumb(transport, 'link ok');
    // Publish where a remote engine finds the phone bridge before `dsh web` starts.
    await _publishPhoneBridge(transport);
    at(HostLinkStep.startDsh, detail: appL10n.remoteCheckingDsh);
    try {
      final bootstrap = RemoteDshBootstrap(
        transport,
        launchCommand: _phoneProfileLaunch ?? _config.launchCommand,
        workingDirectory: _config.workingDirectory,
        environment: remoteEnvironment,
      );
      final endpoint = await bootstrap.ensureRunning(
        forceRestart: _forceRestart,
        onDetail: (d) => at(HostLinkStep.startDsh, detail: d),
      );
      _checkOpen();
      _forceRestart = false;
      await _bridgeBreadcrumb(transport, 'engine port=${endpoint.port} reused=${endpoint.reused}');

      at(HostLinkStep.tunnel, detail: '127.0.0.1:${endpoint.port}');
      try {
        // Destroy a late channel too: Future.timeout does not cancel the
        // underlying SSH channel-open request.
        await transport
            .openTunnel('127.0.0.1', endpoint.port)
            .then((channel) => channel.destroy())
            .timeout(tunnelProbeTimeout);
      } catch (e) {
        // A reused DSH whose port no longer answers: start a fresh one.
        if (endpoint.reused && e is TunnelRefused) _forceRestart = true;
        throw HostLinkError(HostLinkErrorKind.tunnelFailed, appL10n.remoteErrDshPort, detail: '$e', retryable: true);
      }
      await _bridgeBreadcrumb(transport, 'tunnel ok');
      _checkOpen();
      final previous = _endpoint;
      _endpoint = endpoint;
      if (_forwarder == null) {
        final forwarder = await LocalForwarder.bind(_openChannel);
        if (_closed) {
          await forwarder.close();
          throw StateError('link closed');
        }
        _forwarder = forwarder;
      }
      _connectingTransport = null;
      _installTransport(transport);

      at(HostLinkStep.login);
      final client = await _ensureClient(endpoint, previous);
      _checkOpen();
      _emit(
        HostLinkStatus(
          HostLinkPhase.connected,
          completed: HostLinkStep.values.toSet(),
          detail: endpoint.reused ? appL10n.remoteDshReused : appL10n.remoteDshStarted,
        ),
      );
      await _bridgeBreadcrumb(transport, 'client ok');
      _startKeepAlive();
      return client;
    } catch (e) {
      await _bridgeBreadcrumb(transport, 'failed $e');
      transport.close();
      if (identical(_transport, transport)) _teardownTransport();
      rethrow;
    } finally {
      if (identical(_connectingTransport, transport)) _connectingTransport = null;
    }
  }

  Future<DshClient> _ensureClient(RemoteDshEndpoint endpoint, RemoteDshEndpoint? previous) async {
    final existing = _client;
    final sameServer = previous != null && previous.port == endpoint.port && previous.token == endpoint.token;
    if (existing != null && sameServer && !_needsRelogin) {
      // Same process behind the same port: the cookie still works and the mux
      // reconnects through the forwarder by itself. Leave a mux that already
      // recovered alone: reconnect() would drop a healthy generation and make
      // every stream re-open and re-pull its snapshot over the same slow link.
      if (existing.mux.state != DshConnectionState.connected) existing.mux.reconnect();
      return existing;
    }
    // Diagnostics: surface mux/carrier state changes on the host breadcrumb.
    final traceTransport = _transport;
    if (traceTransport != null) {
      dshLinkTrace = (entry) {
        if (entry.channel == 'state') {
          unawaited(_bridgeBreadcrumb(traceTransport, 'mux ${entry.data}'));
        }
        // Carrier/mux state entries carry the WebSocket close code and reason:
        // the only way to tell a server-side heartbeat kill from a local one.
        if (entry.direction == 'state') {
          LinkLossLog.add('carrier', entry.channel, fields: {'data': '${entry.data}'});
        }
      };
    }
    final DshClient client;
    try {
      client = await _connectClient(
        baseUri: Uri(scheme: 'http', host: '127.0.0.1', port: _forwarder!.port),
        token: endpoint.token,
        hostHeader: endpoint.authority,
      );
    } on DshHttpException catch (e) {
      if (e.statusCode == 401 && endpoint.reused) {
        // Stale log from a process that's gone or restarted: start fresh.
        _forceRestart = true;
      }
      throw HostLinkError(
        HostLinkErrorKind.loginFailed,
        e.statusCode == 401 ? appL10n.remoteErrDshTokenRejected : appL10n.remoteErrDshSignIn,
        detail: '$e',
        retryable: true,
      );
    } on DshException catch (e) {
      throw HostLinkError(HostLinkErrorKind.tunnelFailed, appL10n.remoteErrDshTunnel, detail: '$e', retryable: true);
    }
    if (_closed) {
      await client.close().catchError((_) {});
      throw StateError('link closed');
    }
    _needsRelogin = false;
    _client = client;
    _watchMux(client);
    if (existing != null) {
      _clients.add(client);
      unawaited(existing.close().catchError((_) {}));
    }
    return client;
  }

  void _watchMux(DshClient client) {
    unawaited(_muxSub?.cancel());
    // A client handed over while its mux is already retrying starts the grace
    // clock now; otherwise the first state change does.
    if (client.mux.state != DshConnectionState.connected) _muxDownSince ??= DateTime.now();
    _muxSub = client.mux.states.listen((state) {
      if (!identical(client, _client)) return;
      if (state == DshConnectionState.connected) {
        _muxDownSince = null;
      } else {
        _muxDownSince ??= DateTime.now();
        LinkLossLog.add('mux', state.name, fields: {'lastError': '${client.mux.lastError}'});
      }
      if (state == DshConnectionState.unauthorized) {
        _needsRelogin = true;
        _lost(HostLinkError(HostLinkErrorKind.loginFailed, appL10n.remoteErrDshSignInExpired, retryable: true));
      }
    });
  }

  /// SSH answers but the mux can't get through: if nothing listens on DSH's
  /// port any more, reconnect, which starts it again.
  ///
  /// Only a refused connection proves the DSH process is gone. Anything else
  /// (a slow channel open, a gateway refusing direct-tcpip, a timeout) is
  /// inconclusive: tearing the SSH link down for it reconnects every stream,
  /// republishes the phone bridge and restarts DSH's relay - for nothing.
  /// When the port probe is inconclusive, a channel round-trip decides whether
  /// the SSH link itself is still alive; a live link keeps its connection and
  /// lets the mux retry.
  Future<void> _probeDsh() async {
    final transport = _transport;
    final endpoint = _endpoint;
    if (transport == null || endpoint == null || !_status.isConnected) return;
    try {
      // A channel that opens after the timeout is still closed.
      final probe = transport.openTunnel('127.0.0.1', endpoint.port).then((channel) => channel.destroy());
      await probe.timeout(tunnelProbeTimeout);
      return;
    } on TunnelRefused {
      if (!identical(transport, _transport)) return;
      _backoff.reset();
      _lost(HostLinkError(HostLinkErrorKind.dshStartFailed, appL10n.remoteErrDshStopped, retryable: true));
      return;
    } catch (_) {
      // Inconclusive; check SSH below instead of declaring the Host dead.
    }
    // Two consecutive channel round-trips must fail before the SSH link is
    // declared dead: one slow reply is not a lost link.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await transport.run('true', timeout: tunnelProbeTimeout);
        return;
      } catch (_) {
        if (!identical(transport, _transport)) return;
        if (attempt == 0) await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (!identical(transport, _transport)) return;
    _backoff.reset();
    _lost(HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrSshDisconnected, retryable: true));
  }

  void _installTransport(SshTransport transport) {
    _transport = transport;
    if (!_ready.isCompleted) _ready.complete(transport);
    unawaited(
      transport.done.then((_) {
        if (identical(_transport, transport)) {
          _lost(HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrSshDisconnected, retryable: true));
        }
      }),
    );
  }

  final PhoneChannel _phone = PhoneChannel();
  PhoneBridgeLink? _phoneBridge;
  String? _phoneProfileLaunch;

  Future<void> _bridgeBreadcrumb(SshTransport transport, String line) async {
    try {
      await transport.run(
        'mkdir -p ~/.dsh-app-remote && printf \'[%s] %s\\n\' "\$(date -u +%FT%TZ)" '
            '${shQuote('phone-bridge $line')} >> ~/.dsh-app-remote/bridge.log',
        timeout: const Duration(seconds: 10),
      );
    } catch (_) {
      // Diagnostics only.
    }
  }

  Future<void> _publishPhoneBridge(SshTransport transport) async {
    try {
      _phoneBridge = await PhoneBridgeLink.start(transport, _phone).timeout(const Duration(seconds: 12));
      if (_phoneBridge == null) return;
      final homeRes = await transport.run(r'printf %s "$HOME"', timeout: const Duration(seconds: 15));
      final home = homeRes.stdout.trim();
      if (home.isEmpty) return;
      final stateDir = '$home/.dsh';
      final script = _phoneProfileScript.replaceAll('__RELAY_PATH__', '$stateDir/phone-relay.cjs');
      await transport.run(script, timeout: const Duration(seconds: 25));
      final port = _phoneBridge!.hostPort;
      _phoneProfileLaunch = 'dsh --profile web-phone';
      await _bridgeBreadcrumb(transport, 'ok port=${port ?? -1} profile=web-phone');
      // The relay reconnects by itself when the mux port changes, so the engine
      // must never be restarted here: a restart reconnects the app, publishes a
      // new port, and restarts again forever.
    } catch (e) {
      _phoneBridge = null;
      _phoneProfileLaunch = null;
      await _bridgeBreadcrumb(transport, 'failed $e');
    }
  }
  void _teardownTransport() {
    unawaited(_phoneBridge?.close());
    _phoneBridge = null;
    _phoneProfileLaunch = null;
    _keepAlive?.cancel();
    _keepAlive = null;
    _muxDownSince = null;
    _missedPings = 0;
    final transport = _transport;
    _transport = null;
    if (_ready.isCompleted) _ready = Completer<SshTransport>();
    transport?.close();
    _forwarder?.dropConnections();
  }

  /// Channels for the forwarder: waits (bounded) for a live SSH connection.
  Future<TunnelChannel> _openChannel() async {
    _checkOpen();
    final transport = _transport ?? await _ready.future.timeout(const Duration(seconds: 20));
    _checkOpen();
    final port = _endpoint?.port;
    if (port == null) throw StateError('no remote endpoint yet');
    var abandoned = false;
    try {
      return await transport
          .openTunnel('127.0.0.1', port)
          .then((channel) {
            if (abandoned || _closed || !identical(transport, _transport)) {
              channel.destroy();
              throw StateError('SSH channel no longer active');
            }
            return channel;
          })
          .timeout(tunnelProbeTimeout);
    } catch (_) {
      // A timeout does not cancel the SSH request: dispose a late success.
      abandoned = true;
      rethrow;
    }
  }

  void _startKeepAlive() {
    _keepAlive?.cancel();
    _missedPings = 0;
    _keepAlive = Timer.periodic(keepAliveInterval, (_) {
      // Traffic floor: the gateway drops a connection that is idle for ~62s,
      // and one slow tick can outlast an interval. This request is fired on
      // every interval regardless of what the in-flight tick is still doing.
      _nudgeTraffic();
      unawaited(_keepAliveTick());
    });
  }

  bool _nudgeInFlight = false;

  /// Fire-and-forget SSH global keepalive, sent only to reset the gateway's
  /// idle timer. Never awaited: dartssh2 4.1.0 keeps a shared reply queue, so
  /// at most one request may be outstanding at a time and its reply is never
  /// required for the link to be considered alive.
  void _nudgeTraffic() {
    final transport = _transport;
    if (transport == null || _closed || _nudgeInFlight) return;
    _nudgeInFlight = true;
    unawaited(() async {
      try {
        await transport.ping(timeout: _pingRequestTimeout);
      } catch (_) {
        // A gateway may answer late or not at all; the channel round-trip in
        // _ping is the authoritative check.
      } finally {
        _nudgeInFlight = false;
      }
    }());
  }

  Future<void> _keepAliveTick() async {
    // One tick at a time. Timer.periodic keeps firing while a tick awaits a
    // slow ping and its channel fallback, and every overlapping tick used to
    // count its own "missed" ping: one hiccup could produce three.
    if (_keepAliveTickInFlight) return;
    _keepAliveTickInFlight = true;
    try {
      // A live client on a connected mux is the definition of connected. If the
      // published phase disagrees (a status regressed while the client kept
      // working), converge here instead of leaving the UI on "连接服务器…".
      final live = _client;
      if (live != null &&
          live.mux.state == DshConnectionState.connected &&
          _status.phase != HostLinkPhase.connected &&
          !_recovering) {
        _emit(HostLinkStatus(
          HostLinkPhase.connected,
          completed: HostLinkStep.values.toSet(),
          detail: _status.detail,
        ));
      }
      if (!await _ping(keepAliveTimeout)) return;
      if (_client?.mux.state == DshConnectionState.connected) return;
      final downSince = _muxDownSince;
      if (downSince == null) return;
      if (DateTime.now().difference(downSince) < muxProbeDelay) return;
      await _probeDsh();
    } finally {
      _keepAliveTickInFlight = false;
    }
  }

  Future<bool> _ping(Duration timeout) async {
    final transport = _transport;
    if (transport == null || _closed) return false;
    // A global keepalive request is optional for the protocol and its reply
    // is never waited for (see _nudgeTraffic). A real channel round-trip is the
    // authoritative dead-link check and carries its own timeout.
    try {
      await transport.run('true', timeout: timeout);
      _missedPings = 0;
      return true;
    } catch (_) {
      _missedPings++;
      if (_missedPings >= 3 && identical(transport, _transport)) {
        _lost(HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrSshUnresponsive, retryable: true));
      }
      return false;
    }
  }

  void _lost(HostLinkError reason) {
    if (_closed || _recovering || _status.phase == HostLinkPhase.failed) return;
    if (_status.phase != HostLinkPhase.connected) return;
    // Record what the client believed before the link is torn down: the host
    // trace only shows what the Host saw (see the diagnostics bundle).
    LinkLossLog.add('link', reason.kind.name, fields: {
      'message': reason.message,
      'detail': reason.detail,
      'retryable': reason.retryable,
      'missedPings': _missedPings,
    });
    _teardownTransport();
    unawaited(_recover(reason).then((_) {}, onError: (_) {}));
  }

  /// Reconnect loop with backoff. Resolves with the (possibly new) client.
  Future<DshClient> _recover(HostLinkError reason) async {
    _recovering = true;
    var last = reason;
    try {
      while (!_closed) {
        if (_backoff.exhausted) {
          final error = HostLinkError(
            last.kind,
            last.message,
            detail: [if (last.detail != null) last.detail!, appL10n.remoteRetryCount(_backoff.attempt)].join('\n'),
            retryable: true,
          );
          _fail(error);
          throw error;
        }
        final delay = _backoff.next();
        _emit(
          HostLinkStatus(
            HostLinkPhase.reconnecting,
            attempt: _backoff.attempt,
            error: last,
            nextRetryAt: DateTime.now().add(delay),
          ),
        );
        await _delay.wait(delay);
        if (_closed) break;
        try {
          final client = await _connectGuarded();
          _backoff.reset();
          return client;
        } on HostLinkError catch (e) {
          if (_closed) break;
          if (!e.retryable) {
            _fail(e);
            rethrow;
          }
          last = e;
        } catch (e) {
          if (_closed) break;
          last = HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed, detail: '$e', retryable: true);
        }
      }
      throw StateError('link closed');
    } finally {
      _recovering = false;
    }
  }

  /// Kills the current SSH connection as if the network dropped (live tests).
  void debugDropTransport() => _transport?.close();

  @override
  void kick() {
    if (_closed) return;
    switch (_status.phase) {
      case HostLinkPhase.connected:
        // Network changed under us: a quick ping tells whether the socket
        // survived; a dead one triggers reconnect without waiting for the
        // regular keepalive.
        unawaited(() async {
          final alive = await _ping(const Duration(seconds: 5));
          if (!alive) {
            _backoff.reset();
            _lost(HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrSshNetworkChanged, retryable: true));
          }
        }());
      case HostLinkPhase.reconnecting:
        _backoff.reset();
        _delay.skip();
      case HostLinkPhase.failed:
        if (_status.error?.retryable ?? false) retry();
      case HostLinkPhase.idle || HostLinkPhase.connecting:
        break;
    }
  }

  @override
  void retry() {
    if (_closed || _status.isBusy && _status.phase != HostLinkPhase.reconnecting) return;
    if (_status.phase == HostLinkPhase.reconnecting) {
      _backoff.reset();
      _delay.skip();
      return;
    }
    if (_status.phase == HostLinkPhase.connected) unawaited(_probeDsh());
    if (_status.phase == HostLinkPhase.failed || _status.phase == HostLinkPhase.idle) {
      unawaited(open().then((_) {}, onError: (_) {}));
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _emit(HostLinkStatus.idle);
    _closed = true;
    _delay.cancel();
    final connecting = _connectingTransport;
    _connectingTransport = null;
    connecting?.close();
    await _kickSub?.cancel();
    await _muxSub?.cancel();
    _teardownTransport();
    await _forwarder?.close();
    _forwarder = null;
    final client = _client;
    _client = null;
    if (client != null) await client.close().catchError((_) {});
    await _statuses.close();
    await _clients.close();
  }
}

/// Connects just far enough to read the server's host key, without logging
/// in: used to ask "trust this host?" before a host becomes active.
Future<PresentedHostKey> fetchHostKey(SshHostConfig config, {SshTransportFactory? transportFactory}) async {
  PresentedHostKey? seen;
  // A dummy password: verification happens before authentication, and the
  // verifier refuses, so nothing is ever sent.
  final params = SshConnectParams(
    host: config.host.trim(),
    port: config.port,
    username: config.user.trim(),
    auth: SshAuthMethod.password,
    secrets: const SshSecrets(password: 'x'),
  );
  try {
    final transport = await (transportFactory ?? DartSshTransport.connect)(params, (key) {
      seen = key;
      return false;
    });
    transport.close();
  } catch (e) {
    if (seen != null) return seen!;
    if (e is HostLinkError) rethrow;
    throw HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrReadFingerprint, detail: '$e', retryable: true);
  }
  if (seen != null) return seen!;
  throw HostLinkError(HostLinkErrorKind.other, appL10n.remoteErrNoFingerprint);
}
