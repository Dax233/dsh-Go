// Small parts every workshop page shares: the item's square, the capsule at
// the end of a row, and the quiet line that says something went wrong without
// taking the page over.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../workshop/workshop_models.dart';
import '../plugins/plugin_widgets.dart' show PluginAvatar;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_text.dart';

/// The item's square, app-store style. The catalogue carries no picture yet,
/// so this is the title's first letter on a tint the item keeps.
class WorkshopAvatar extends StatelessWidget {
  const WorkshopAvatar(this.metadata, {super.key, this.size = 40});

  final WorkshopMetadata metadata;
  final double size;

  @override
  Widget build(BuildContext context) => PluginAvatar(
    name: metadata.identity,
    title: workshopTitleOf(metadata, Localizations.localeOf(context).languageCode),
    size: size,
  );
}

/// What the capsule at the end of a row offers.
enum WorkshopGetState { get, update, installed, running }

/// 获取 / 更新 / 已安装, or a small ring while this item is being installed.
/// Every state opens the detail sheet; installing always goes through it.
class WorkshopGetButton extends StatelessWidget {
  const WorkshopGetButton({super.key, required this.state, this.onPressed});

  final WorkshopGetState state;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final installed = state == WorkshopGetState.installed;
    final running = state == WorkshopGetState.running;
    final track = dark ? Colors.white.withValues(alpha: 0.09) : scheme.onSurface.withValues(alpha: 0.06);
    final fg = installed ? colors.textTertiary : scheme.primary;
    final label = switch (state) {
      WorkshopGetState.get => l10n.workshopGet,
      WorkshopGetState.update => l10n.commonUpdate,
      WorkshopGetState.installed => l10n.commonInstalled,
      WorkshopGetState.running => l10n.pluginsInstalling,
    };
    return FilledButton.tonal(
      style: FilledButton.styleFrom(
        backgroundColor: installed ? Colors.transparent : track,
        foregroundColor: fg,
        minimumSize: const Size(68, 30),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        shape: const StadiumBorder(),
        elevation: 0,
        textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 13.5),
      ),
      onPressed: onPressed,
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.quick),
        child: Row(
          key: ValueKey(label),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (running) ...[
              SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 1.8, strokeCap: StrokeCap.round, color: fg),
              ),
              const SizedBox(width: 6),
            ],
            Text(label),
          ],
        ),
      ),
    );
  }
}

/// How loud a [WorkshopNote] is.
enum WorkshopNoteTone { quiet, warning, danger }

/// One or two lines beside a small mark: a refresh that failed, a version
/// that was withdrawn. It sits in the page's flow and leaves the content up.
class WorkshopNote extends StatelessWidget {
  const WorkshopNote(
    this.text, {
    super.key,
    this.tone = WorkshopNoteTone.quiet,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(24, 0, 16, 12),
  });

  final String text;
  final WorkshopNoteTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final color = switch (tone) {
      WorkshopNoteTone.quiet => colors.textTertiary,
      WorkshopNoteTone.warning => colors.warning,
      WorkshopNoteTone.danger => colors.danger,
    };
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(tone == WorkshopNoteTone.quiet ? AppIcons.info : AppIcons.warning, size: 16, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: tone == WorkshopNoteTone.quiet ? colors.textTertiary : theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 4),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(44, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
