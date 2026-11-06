import 'dart:io';

import 'package:flutter/material.dart';

import 'theme.dart';

/// A screen: title, optional subtitle and actions, then the body. Actions
/// wrap under the title on narrow windows; the page fades in when opened.
class PageFrame extends StatefulWidget {
  const PageFrame({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    required this.child,
    this.scroll = true,
  });
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;
  final bool scroll;

  @override
  State<PageFrame> createState() => _PageFrameState();
}

class _PageFrameState extends State<PageFrame> {
  // Each page owns its scroll position (several Studio pages stay mounted).
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    final PageFrame(:title, :subtitle, :actions, :child, :scroll) = widget;
    return LayoutBuilder(
      builder: (context, box) {
        final pad = Space.page(box.maxWidth);
        final narrow = box.maxWidth < 760;
        final titles = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(title, style: text.headlineSmall),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: Space.x1),
              Text(subtitle, style: text.bodyMedium?.copyWith(color: t.faint)),
            ],
          ],
        );
        final acts = Wrap(
          spacing: Space.x2,
          runSpacing: Space.x2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        );
        final head = Padding(
          padding: EdgeInsets.fromLTRB(pad, Space.x5, pad, Space.x3),
          child: narrow || actions.isEmpty
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    titles,
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: Space.x3),
                      acts,
                    ],
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: titles),
                    const SizedBox(width: Space.x4),
                    Flexible(
                      child: Align(alignment: Alignment.topRight, child: acts),
                    ),
                  ],
                ),
        );
        final body = Padding(
          padding: EdgeInsets.fromLTRB(pad, 0, pad, Space.x6),
          child: child,
        );
        return FadeIn(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              head,
              Expanded(
                child: scroll
                    ? Scrollbar(
                        controller: _scroll,
                        child: SingleChildScrollView(
                          controller: _scroll,
                          child: body,
                        ),
                      )
                    : body,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Fades and lifts its child in once, when it first appears (page and panel
/// entrances). Nothing moves with Motion: Reduced.
class FadeIn extends StatefulWidget {
  const FadeIn({super.key, required this.child, this.offset = 6});
  final Widget child;
  final double offset;
  @override
  State<FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final d = Motion.base(context);
    if (d == Duration.zero) {
      _c.value = 1;
    } else {
      _c
        ..duration = d
        ..forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = CurvedAnimation(parent: _c, curve: Motion.standard);
    return AnimatedBuilder(
      animation: a,
      child: widget.child,
      builder: (_, child) => Opacity(
        opacity: a.value,
        child: Transform.translate(
          offset: Offset(0, (1 - a.value) * widget.offset),
          child: child,
        ),
      ),
    );
  }
}

/// A card with an optional title row.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(Space.x4),
  });
  final String? title, subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.x3),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: Space.x3,
                  runSpacing: Space.x2,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(title!, style: text.titleMedium),
                        ),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle!,
                              style: text.bodySmall?.copyWith(color: t.faint),
                            ),
                          ),
                      ],
                    ),
                    ?trailing,
                  ],
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }
}

/// A small upper-case label above a group of controls.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.x2, bottom: Space.x2),
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              text.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(letterSpacing: 0.8),
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class StatTile extends StatefulWidget {
  const StatTile(
    this.label,
    this.value, {
    super.key,
    this.warn = false,
    this.onTap,
  });
  final String label, value;
  final bool warn;
  final VoidCallback? onTap;
  @override
  State<StatTile> createState() => _StatTileState();
}

class _StatTileState extends State<StatTile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    final active = _hover && widget.onTap != null;
    return Semantics(
      button: widget.onTap != null,
      label: '${widget.label}: ${widget.value}',
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: widget.onTap != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        child: AnimatedContainer(
          duration: Motion.fast(context),
          curve: Motion.standard,
          width: 168,
          decoration: BoxDecoration(
            color: active ? t.panel2 : t.panel,
            borderRadius: Radii.large,
            border: Border.all(color: active ? t.lineStrong : t.line),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: Radii.large,
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.all(Space.x3 + 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: t.faint),
                    ),
                    const SizedBox(height: Space.x1 + 2),
                    Text(
                      widget.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.headlineSmall?.copyWith(
                        color: widget.warn ? t.warn : null,
                        fontFeatures: DjType.tabular,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.x8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: FadeIn(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: t.tint(t.accent, 0.12),
                    borderRadius: Radii.large,
                    border: Border.all(color: t.tint(t.accent, 0.24)),
                  ),
                  child: Icon(icon, color: t.accent, size: IconSizes.xl),
                ),
                const SizedBox(height: Space.x4),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: text.titleLarge,
                ),
                if (message != null) ...[
                  const SizedBox(height: Space.x2),
                  Text(
                    message!,
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: t.faint),
                  ),
                ],
                if (action != null) ...[
                  const SizedBox(height: Space.x5),
                  action!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A page or panel that is still loading.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label = 'Loading…'});
  final String label;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    return Center(
      child: Semantics(
        liveRegion: true,
        label: label,
        child: Padding(
          padding: const EdgeInsets.all(Space.x6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(height: Space.x3),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: t.faint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Something went wrong: what, and what the DJ can do about it.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key, this.action, this.icon});
  final String message;
  final Widget? action;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(Space.x3),
        decoration: BoxDecoration(
          color: t.tint(t.danger, 0.10),
          borderRadius: Radii.medium,
          border: Border.all(color: t.tint(t.danger, 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon ?? Icons.error_outline,
              color: t.danger,
              size: IconSizes.md,
            ),
            const SizedBox(width: Space.x2 + 2),
            Expanded(
              child: SelectableText(
                message,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (action != null) ...[const SizedBox(width: Space.x2), action!],
          ],
        ),
      ),
    );
  }
}

class ColorDot extends StatelessWidget {
  const ColorDot(this.color, {super.key, this.size = 10});
  final String? color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: crateColors[color] ?? Colors.transparent,
      shape: BoxShape.circle,
      border: crateColors[color] == null
          ? Border.all(color: DjTokens.of(context).faint)
          : null,
    ),
  );
}

/// A small rounded label.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color, this.tooltip});
  final String text;
  final Color? color;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final c = color ?? t.muted;
    final w = Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.x2, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: Radii.small,
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: c, fontFeatures: DjType.tabular),
      ),
    );
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

/// A line of muted explanatory text.
class HintText extends StatelessWidget {
  const HintText(this.text, {super.key, this.icon});
  final String text;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: IconSizes.sm, color: t.faint),
          const SizedBox(width: Space.x1 + 2),
        ],
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: t.faint),
          ),
        ),
      ],
    );
  }
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String ok = 'Continue',
  bool danger = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Text(message),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: DjTokens.of(c).danger)
              : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> askText(
  BuildContext context, {
  required String title,
  String label = '',
  String initial = '',
  String ok = 'Save',
  bool obscure = false,
}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: ctl,
          autofocus: true,
          obscureText: obscure,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, ctl.text),
          child: Text(ok),
        ),
      ],
    ),
  );
}

/// A labelled progress bar for a job or scan.
class ProgressLine extends StatelessWidget {
  const ProgressLine({
    super.key,
    required this.label,
    this.done = 0,
    this.total = 0,
    this.message,
  });
  final String label;
  final int done, total;
  final String? message;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.titleSmall),
            ),
            if (total > 0)
              Text(
                '$done / $total',
                style: TextStyle(color: t.faint, fontFeatures: DjType.tabular),
              ),
          ],
        ),
        const SizedBox(height: Space.x1 + 2),
        TweenAnimationBuilder<double>(
          tween: Tween(end: total > 0 ? (done / total).clamp(0, 1) : 0),
          duration: Motion.base(context),
          curve: Motion.standard,
          builder: (_, v, _) => LinearProgressIndicator(
            minHeight: 6,
            value: total > 0 ? v : null,
            semanticsLabel: label,
            semanticsValue: total > 0 ? '$done of $total' : null,
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: Space.x1),
          Text(
            message!,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: t.faint),
          ),
        ],
      ],
    );
  }
}

/// Space between stacked panels.
const gap = SizedBox(height: Space.x4, width: Space.x4);

/// Opens an https link in the default browser (store links, key pages).
Future<void> openUrl(String url) async {
  if (!url.startsWith('https://')) return;
  if (Platform.isWindows) {
    await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [url]);
  } else {
    await Process.run('xdg-open', [url]);
  }
}
