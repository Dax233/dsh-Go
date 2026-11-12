import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/ssh/instabox_activity.dart';
import '../../remote/ssh/instabox_wake.dart';
import '../../remote/link_status.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/brief_notice.dart';
import '../common/app_sheet.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

Future<void> showRemoteNetworkDetails(BuildContext context, HostRef host) => showAppSheet<void>(
  context,
  dismissal: SheetDismissal.button,
  isScrollControlled: true,
  builder: (_) => RemoteNetworkDetailsSheet(host: host),
);

/// Only route names, timings and IP/protocol enums reach this surface.
/// Candidate addresses, credentials and raw errors never belong in this sheet.
class RemoteNetworkDetailsSheet extends ConsumerStatefulWidget {
  const RemoteNetworkDetailsSheet({super.key, required this.host});

  final HostRef host;

  @override
  ConsumerState<RemoteNetworkDetailsSheet> createState() => _RemoteNetworkDetailsSheetState();
}

class _RemoteNetworkDetailsSheetState extends ConsumerState<RemoteNetworkDetailsSheet> {
  bool _measuring = false;
  bool _failed = false;

  Future<void> _measure() async {
    final link = ref.read(hostLinkProvider(widget.host));
    if (link is! NetworkInspectableHostLink) {
      setState(() => _failed = true);
      return;
    }
    setState(() {
      _measuring = true;
      _failed = false;
    });
    try {
      final result = await (link as NetworkInspectableHostLink).inspectNetwork();
      if (!mounted || !identical(ref.read(hostLinkProvider(widget.host)), link)) return;
      if (ref.read(hostLinkStatusProvider(widget.host)).value?.isConnected != true) return;
      setState(() => _failed = result == null || result.roundTripTime == null);
    } catch (_) {
      if (mounted && identical(ref.read(hostLinkProvider(widget.host)), link)) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted) setState(() => _measuring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final status = ref.watch(hostLinkStatusProvider(widget.host)).value ?? HostLinkStatus.idle;
    final name = ref.watch(hostNameProvider(widget.host)) ?? l10n.commonRemoteHost;
    final relay = widget.host.kind == HostKind.relay;
    // Only the InstaBox host in this build has a machine record to show.
    final sshConfig = widget.host.kind == HostKind.ssh
        ? ref.watch(hostsProvider).sshById(widget.host.id)
        : null;
    final instabox = sshConfig != null && instaboxWakePossibleFor(sshConfig.host);
    final connected = status.isConnected;
    final network = connected && relay ? status.network : null;
    final path = connected && relay ? network?.path ?? status.path : null;
    final observedAt = network?.observedAt?.toLocal();
    final material = MaterialLocalizations.of(context);
    final observedLabel = observedAt == null
        ? null
        : '${material.formatCompactDate(observedAt)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(observedAt), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
    String timing(Duration? value) =>
        value == null ? l10n.remoteNetworkUnmeasured : l10n.remoteNetworkMilliseconds(value.inMilliseconds);
    String ipVersion(NetworkIpVersion? value) => switch (value) {
      NetworkIpVersion.ipv4 => 'IPv4',
      NetworkIpVersion.ipv6 => 'IPv6',
      null => l10n.remoteNetworkUnknownPath,
    };
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(l10n.remoteNetworkDetails),
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
              child: Text(
                relay
                    ? '${l10n.remoteNetworkAutomatic}\n${l10n.remoteNetworkSnapshotHint}'
                    : l10n.hostDetailsSshNetworkHint,
                style: TextStyle(color: colors.textTertiary),
              ),
            ),
            SheetGroup(
              children: [
                _NetworkValue(label: l10n.remoteHost, value: name),
                _NetworkValue(label: l10n.hostDetailsConnectionType, value: relay ? 'DSH Remote' : 'SSH'),
                _NetworkValue(label: l10n.commonStatus, value: status.summary),
                _NetworkValue(
                  label: l10n.remoteNetworkCurrentPath,
                  value: connected && widget.host.kind == HostKind.ssh
                      ? 'SSH'
                      : path?.label ?? l10n.remoteNetworkUnknownPath,
                ),
                _NetworkValue(label: l10n.remoteNetworkConnectDuration, value: timing(network?.connectDuration)),
                _NetworkValue(label: l10n.remoteNetworkRoundTripTime, value: timing(network?.roundTripTime)),
                if (relay && connected && path != null && path != RelayPath.relay) ...[
                  _NetworkValue(label: l10n.remoteNetworkLocalIpVersion, value: ipVersion(network?.localIpVersion)),
                  _NetworkValue(label: l10n.remoteNetworkRemoteIpVersion, value: ipVersion(network?.remoteIpVersion)),
                  _NetworkValue(
                    label: l10n.remoteNetworkIceProtocol,
                    value: network?.iceProtocol?.name.toUpperCase() ?? l10n.remoteNetworkUnknownPath,
                  ),
                ],
                if (observedLabel != null) _NetworkValue(label: l10n.remoteNetworkObservedAt, value: observedLabel),
                if (network?.fallbackReason != null)
                  _NetworkValue(
                    label: l10n.remoteNetworkFallback,
                    value: _fallbackLabel(l10n, network!.fallbackReason!),
                  ),
              ],
            ),
            if (instabox) const _InstaboxSection(),
            if (relay)
              Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 8, kSheetGutter, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!connected || _failed) ...[
                      Text(
                        connected ? l10n.remoteNetworkMeasureFailed : l10n.remoteNetworkDisconnected,
                        style: TextStyle(color: colors.textTertiary),
                      ),
                      const SizedBox(height: 10),
                    ],
                    FilledButton.icon(
                      onPressed: connected && !_measuring ? _measure : null,
                      icon: _measuring
                          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(AppIcons.refresh, size: 18),
                      label: Text(_measuring ? l10n.remoteNetworkMeasuring : l10n.remoteNetworkMeasure),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NetworkValue extends StatelessWidget {
  const _NetworkValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(label, style: TextStyle(color: DshColors.of(context).textTertiary)),
        ),
        const SizedBox(width: 16),
        Expanded(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );
}

String _fallbackLabel(L10n l10n, String code) => switch (code) {
  'webrtcUnavailable' => l10n.remoteNetworkFallbackWebrtcUnavailable,
  'directFailed' => l10n.remoteNetworkFallbackDirectFailed,
  'directTimeout' => l10n.remoteNetworkFallbackDirectTimeout,
  'directRecentlyFailed' => l10n.remoteNetworkFallbackDirectRecentlyFailed,
  'turnUnavailable' => l10n.remoteNetworkFallbackTurnUnavailable,
  'turnFailed' => l10n.remoteNetworkFallbackTurnFailed,
  'turnTimeout' => l10n.remoteNetworkFallbackTurnTimeout,
  'pathUnverified' => l10n.remoteNetworkFallbackPathUnverified,
  _ => l10n.remoteNetworkFallbackUnknown,
};

/// InstaBox keeps the run clock on its side: the limit shown here is this run's,
/// and pausing then resuming ends the run without owing a cooldown.
class _InstaboxSection extends ConsumerStatefulWidget {
  const _InstaboxSection();

  @override
  ConsumerState<_InstaboxSection> createState() => _InstaboxSectionState();
}

class _InstaboxSectionState extends ConsumerState<_InstaboxSection> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      await InstaboxActivityKeeper.readMachine();
    } catch (_) {
      // A machine that cannot be read (offline, no key) simply shows nothing.
    }
  }

  Future<void> _reset() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.instaboxResetTitle),
        content: Text(l10n.instaboxResetBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            key: const ValueKey("instabox-reset-confirm"),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.instaboxResetAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final code = await InstaboxActivityKeeper.resetRun();
    if (!mounted) return;
    setState(() => _busy = false);
    showBriefNotice(
      context,
      code == null ? l10n.instaboxResetDone : l10n.instaboxResetFailed(code),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final keep = InstaboxActivityLog.snapshot();
    final leases = (keep["leasesOk"] as int?) ?? 0;
    final work = (keep["workOk"] as int?) ?? 0;
    return ValueListenableBuilder<InstaboxMachineSnapshot?>(
      valueListenable: instaboxMachine,
      builder: (context, snapshot, _) {
        final state = switch (snapshot?.state) {
          "running" => l10n.instaboxStateRunning,
          "suspended" => l10n.instaboxStatePaused,
          _ => l10n.instaboxStateUnknown,
        };
        String minutes(int? value) =>
            value == null ? l10n.instaboxUnread : l10n.instaboxMinutesValue(value);
        final startedAt = snapshot?.runStartedAt;
        final elapsed = startedAt == null
            ? null
            : DateTime.now().toUtc().difference(startedAt).inMinutes;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 12, kSheetGutter, 6),
              child: Text(l10n.instaboxSectionTitle, style: TextStyle(color: colors.textTertiary)),
            ),
            SheetGroup(
              children: [
                _NetworkValue(label: l10n.instaboxStateLabel, value: state),
                _NetworkValue(label: l10n.instaboxRunLimitLabel, value: minutes(snapshot?.maxRunMinutes)),
                _NetworkValue(label: l10n.instaboxRunElapsedLabel, value: minutes(elapsed)),
                _NetworkValue(label: l10n.instaboxRemainingLabel, value: minutes(snapshot?.remainingMinutes)),
                _NetworkValue(
                  label: l10n.instaboxKeepaliveLabel,
                  value: l10n.instaboxKeepaliveValue(leases, work),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 8, kSheetGutter, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (snapshot?.nearLimit == true) ...[
                    Text(l10n.instaboxNearLimit, style: TextStyle(color: colors.textTertiary)),
                    const SizedBox(height: 8),
                  ],
                  FilledButton.icon(
                    key: const ValueKey("instabox-reset"),
                    onPressed: _busy ? null : _reset,
                    icon: _busy
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(AppIcons.refresh, size: 18),
                    label: Text(l10n.instaboxResetAction),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: _busy ? null : () => unawaited(_refresh()),
                    child: Text(l10n.instaboxRefreshAction),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
