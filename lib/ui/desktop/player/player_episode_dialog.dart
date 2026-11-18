import 'package:flutter/material.dart';

import '../../../core/player/cross_site_failover_planner.dart';
import '../../../core/player/source_candidates.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';
import 'episode_drawer.dart';

/// 播放页「选集播放」居中弹窗（替代原先右侧抽屉）。
///
/// 布局参照详情页的「选集播放」：**左侧是播放源、右侧是选集网格**。
/// 左侧既列本片线路（`nav.lines`），也列跨站搜索到的其他来源（按延迟升序），
/// 用户在一屏里就能决定「换源」还是「换集」。
///
/// 与抽屉相比它更直观，但**不接管键盘焦点**：Esc 仍由播放器的退出链路先收它
/// （`_handleExit` 里 `_episodeDrawerOpen` 优先），快捷键在弹窗期间被禁用。
class PlayerEpisodeDialogLayer extends StatefulWidget {
  const PlayerEpisodeDialogLayer({
    super.key,
    required this.open,
    required this.nav,
    required this.onClose,
    required this.child,
  });

  final bool open;
  final PlayerEpisodeListNav? nav;
  final VoidCallback onClose;
  final Widget child;

  @override
  State<PlayerEpisodeDialogLayer> createState() =>
      _PlayerEpisodeDialogLayerState();
}

class _PlayerEpisodeDialogLayerState extends State<PlayerEpisodeDialogLayer> {
  @override
  void initState() {
    super.initState();
    if (widget.open) _ensureCandidates();
  }

  @override
  void didUpdateWidget(covariant PlayerEpisodeDialogLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open && !oldWidget.open) _ensureCandidates();
  }

  /// 打开即自动跨站搜「其他来源」：同一集搜过会复用结果，不会重复等。
  void _ensureCandidates() {
    final candidatesNav = widget.nav?.sourceCandidates;
    final episodeKey = widget.nav?.episodeKey ?? '';
    if (candidatesNav != null && episodeKey.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.open) return;
        candidatesNav.onEnsure(episodeKey);
      });
    }
    // 把当前集滚进可视区（3 列，行高约 62）。
    final index = widget.nav?.episodes.indexWhere((e) => e.current) ?? -1;
    if (index > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_gridController.hasClients) return;
        final offset = (index ~/ 3) * 62.0;
        _gridController.jumpTo(
            offset.clamp(0.0, _gridController.position.maxScrollExtent));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = widget.nav;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (nav != null) ...[
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !widget.open,
              child: AnimatedOpacity(
                duration: widget.open ? AppMotion.enter : AppMotion.exit,
                opacity: widget.open ? 1 : 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onClose,
                  child: const ColoredBox(color: Color(0x88000000)),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !widget.open,
              child: Center(
                child: AnimatedScale(
                  duration: widget.open ? AppMotion.enter : AppMotion.exit,
                  curve: AppMotion.ease,
                  scale: widget.open ? 1 : 0.96,
                  child: AnimatedOpacity(
                    duration: widget.open ? AppMotion.enter : AppMotion.exit,
                    opacity: widget.open ? 1 : 0,
                    child: _buildCard(context, nav),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCard(BuildContext context, PlayerEpisodeListNav nav) {
    final palette = context.palette;
    final screen = MediaQuery.sizeOf(context);
    final width = screen.width < 980 ? screen.width * 0.92 : 940.0;
    final height = screen.height < 660 ? screen.height * 0.9 : 620.0;
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.playerChrome,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(color: context.glassBorder),
          boxShadow: AppShadows.cardHover(palette.accent),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 320,
                child: _buildSourceColumn(context, nav, palette),
              ),
              Container(width: 1, color: palette.playerText.withValues(alpha: 0.08)),
              Expanded(child: _buildEpisodeColumn(context, nav, palette)),
            ],
          ),
        ),
      ),
    );
  }

  // --- 左：播放源 -----------------------------------------------------------

  Widget _buildSourceColumn(
      BuildContext context, PlayerEpisodeListNav nav, AppPalette palette) {
    final ink = palette.playerText;
    final candidatesNav = nav.sourceCandidates;
    final state = candidatesNav?.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: Row(
            children: [
              Icon(Icons.playlist_play_rounded, size: 18, color: palette.accentInk),
              const SizedBox(width: 8),
              Text('播放源',
                  style: TextStyle(
                      color: ink,
                      fontSize: AppType.label,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              if (candidatesNav != null)
                IconButton(
                  tooltip: '重新搜索其他来源',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  onPressed: state?.searching == true
                      ? null
                      : () => candidatesNav.onEnsure(nav.episodeKey),
                  icon: Icon(Icons.refresh_rounded, color: ink),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: ink.withValues(alpha: 0.08)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            children: [
              if (nav.lines.length > 1) ...[
                _sectionLabel(palette, '本片线路'),
                for (final line in nav.lines)
                  _sourceRow(
                    context,
                    palette,
                    title: line.name,
                    subtitle: line.unavailable ? '该线路不可用' : null,
                    trailing: line.current ? '当前' : null,
                    enabled: !nav.switching && !line.current && !line.unavailable,
                    onTap: () => nav.onSelectLine(line.index),
                  ),
              ],
              if (candidatesNav != null) ...[
                _sectionLabel(palette, '其他来源'),
                if (state == null || (!state.searched && !state.searching))
                  _hint(palette, '打开时自动搜索')
                else if (state.searching)
                  _hint(palette, '自动搜索中…')
                else if (state.hasCandidates) ...[
                  for (final candidate in state.candidates)
                    _candidateRow(
                        context, palette, candidatesNav, state, candidate),
                  if (state.candidates
                      .any((candidate) => state.probeFor(candidate) == null))
                    _hint(palette, '正在检测可用性…'),
                ] else
                  _hint(palette, state.message ?? '没有找到其他来源'),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(AppPalette palette, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
        child: Text(text,
            style: TextStyle(
                color: palette.playerText.withValues(alpha: 0.55),
                fontSize: AppType.caption,
                fontWeight: FontWeight.w600)),
      );

  Widget _hint(AppPalette palette, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        child: Text(text,
            style: TextStyle(
                color: palette.playerText.withValues(alpha: 0.55),
                fontSize: AppType.caption)),
      );

  Widget _candidateRow(
      BuildContext context,
      AppPalette palette,
      PlayerSourceCandidatesNav candidatesNav,
      SourceCandidatesState state,
      CrossSiteCandidate candidate) {
    final probe = state.probeFor(candidate);
    final searchLatency = candidate.latencyMs;
    final searchColor = searchLatency <= 0
        ? palette.playerText.withValues(alpha: 0.5)
        : searchLatency < 400
            ? palette.success
            : searchLatency < 1200
                ? palette.playerText.withValues(alpha: 0.75)
                : palette.warning;
    // 体检结果优先：可用显示「✓ 实测耗时」，不可用显示「✗ 原因」，
    // 还没测到就先显示搜索耗时（灰一点，避免和实测混淆）。
    final String trailing;
    final Color trailingColor;
    if (probe == null) {
      trailing = formatLatency(searchLatency);
      trailingColor = searchColor.withValues(alpha: 0.6);
    } else if (probe.ok) {
      trailing = '✓ ${formatLatency(probe.ms)}';
      trailingColor = palette.success;
    } else {
      trailing = '✗ ${probe.reason ?? '不可用'}';
      trailingColor = palette.warning;
    }
    return _sourceRow(
      context,
      palette,
      title: '${candidate.site.name} · ${candidate.source.name}',
      subtitle: '${candidate.episodeName}'
          '${candidate.confidence == CrossSiteConfidence.high ? '' : ' · 请确认'}',
      trailing: trailing,
      trailingColor: trailingColor,
      dim: probe?.ok == false,
      onTap: () => candidatesNav.onSelect(candidate),
    );
  }

  Widget _sourceRow(
    BuildContext context,
    AppPalette palette, {
    required String title,
    String? subtitle,
    String? trailing,
    Color? trailingColor,
    bool enabled = true,
    bool dim = false,
    required VoidCallback onTap,
  }) {
    final ink = palette.playerText;
    final titleColor = !enabled
        ? ink.withValues(alpha: 0.45)
        : dim
            ? ink.withValues(alpha: 0.6)
            : ink;
    return FocusRing(
      onTap: enabled ? onTap : null,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: titleColor, fontSize: AppType.body)),
                      if (subtitle != null)
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: ink.withValues(alpha: 0.5),
                                fontSize: AppType.caption)),
                    ],
                  ),
                ),
                if (trailing != null)
                  Text(trailing,
                      style: TextStyle(
                          color: trailingColor ?? palette.accentInk,
                          fontSize: AppType.caption,
                          fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- 右：选集网格 ---------------------------------------------------------

  Widget _buildEpisodeColumn(
      BuildContext context, PlayerEpisodeListNav nav, AppPalette palette) {
    final ink = palette.playerText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
          child: Row(
            children: [
              Icon(Icons.grid_view_rounded, size: 18, color: palette.accentInk),
              const SizedBox(width: 8),
              Text('选集播放',
                  style: TextStyle(
                      color: ink,
                      fontSize: AppType.label,
                      fontWeight: FontWeight.bold)),
              const SizedBox(width: 10),
              Text('共 ${nav.episodes.length} 集 · ${nav.lineName ?? ''}',
                  style: TextStyle(
                      color: ink.withValues(alpha: 0.55),
                      fontSize: AppType.caption)),
              const Spacer(),
              IconButton(
                tooltip: '关闭',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: widget.onClose,
                icon: Icon(Icons.close_rounded, color: ink),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: ink.withValues(alpha: 0.08)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            child: GridView.builder(
              controller: _gridController,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.5,
              ),
              itemCount: nav.episodes.length,
              itemBuilder: (context, index) =>
                  _buildEpisodeCell(context, nav, palette, index),
            ),
          ),
        ),
      ],
    );
  }

  late final ScrollController _gridController = ScrollController();

  @override
  void dispose() {
    _gridController.dispose();
    super.dispose();
  }

  Widget _buildEpisodeCell(BuildContext context, PlayerEpisodeListNav nav,
      AppPalette palette, int index) {
    final episode = nav.episodes[index];
    final current = episode.current;
    final ink = palette.playerText;
    return FocusRing(
      onTap: nav.switching
          ? null
          : () {
              nav.onSelectEpisode(index);
              widget.onClose();
            },
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: nav.switching
            ? null
            : () {
                nav.onSelectEpisode(index);
                widget.onClose();
              },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: current
                  ? palette.accentInk.withValues(alpha: 0.22)
                  : palette.playerText.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(
                color: current
                    ? palette.accentInk.withValues(alpha: 0.6)
                    : Colors.transparent,
              ),
            ),
            child: Text(
              episode.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ink,
                fontSize: AppType.body,
                fontWeight: current ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
