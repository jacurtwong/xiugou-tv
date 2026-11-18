import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/player/ad_filter_debug.dart';
import '../../../core/player/hls_ad_filter.dart';
import '../../../core/player/player_engine.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 播放器内的「广告调试」面板（默认 D 键开关，与 KimBoxPC 的按键习惯一致）。
///
/// 只读展示本集的剪辑结论：剪了几段、每段起止、每个 chunk 的时长/分片数，
/// 以及**没剪的原因**（开关关着 / 非 m3u8 / 直播 / 系统代理 / 拉取失败……）。
/// 数据源是 `PlayerEngine.adFilterDebug`，换集时引擎会把它清空。
class AdDebugPanel extends StatefulWidget {
  const AdDebugPanel({
    super.key,
    required this.engine,
    required this.onClose,
  });

  final PlayerEngine engine;
  final VoidCallback onClose;

  @override
  State<AdDebugPanel> createState() => _AdDebugPanelState();
}

class _AdDebugPanelState extends State<AdDebugPanel> {
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy(AdFilterDebugInfo info) async {
    await Clipboard.setData(ClipboardData(text: info.toReportText()));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      width: 392,
      constraints: const BoxConstraints(maxHeight: 460),
      decoration: BoxDecoration(
        color: palette.playerChrome,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: context.glassBorder),
        boxShadow: AppShadows.cardHover(palette.accent),
      ),
      child: ValueListenableBuilder<AdFilterDebugInfo?>(
        valueListenable: widget.engine.adFilterDebug,
        builder: (context, info, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(palette, info),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
                  child: info == null
                      ? _buildEmpty(palette)
                      : _buildBody(palette, info),
                ),
              ),
              _buildFooter(palette, info),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(AppPalette palette, AdFilterDebugInfo? info) {
    final outcome = info?.outcome;
    final color = switch (outcome) {
      AdFilterOutcome.filtered => palette.success,
      AdFilterOutcome.master => palette.accent,
      null => palette.textDim,
      _ => palette.warning,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.xs),
      child: Row(
        children: [
          Icon(Icons.bug_report_outlined, size: 15, color: color),
          const SizedBox(width: 6),
          Text('广告调试',
              style: TextStyle(
                  color: palette.playerText,
                  fontSize: AppType.label,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          if (outcome != null)
            Flexible(
              child: Text(outcome.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: AppType.caption)),
            ),
          const Spacer(),
          IconButton(
            tooltip: '关闭（D）',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: widget.onClose,
            icon: Icon(Icons.close_rounded, color: palette.playerText),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(AppPalette palette) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Text('本集还没有剪辑结论（起播后会在这里显示）。',
            style: TextStyle(color: palette.playerText, fontSize: AppType.body)),
      );

  Widget _buildBody(AppPalette palette, AdFilterDebugInfo info) {
    final rows = <Widget>[];
    void addRow(String label, String value, {Color? valueColor}) {
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 44,
              child: Text(label,
                  style: TextStyle(
                      color: palette.playerText.withValues(alpha: 0.62),
                      fontSize: AppType.caption)),
            ),
            Expanded(
              child: Text(value,
                  style: TextStyle(
                      color: valueColor ?? palette.playerText,
                      fontSize: AppType.caption,
                      height: 1.4)),
            ),
          ],
        ),
      ));
    }

    addRow('标题', info.title?.trim().isNotEmpty == true ? info.title! : '—');
    addRow('源主机', info.sourceHost.isEmpty ? '—' : info.sourceHost);
    if (info.proxyHost.isNotEmpty) {
      addRow('中转', '本地代理 ${info.proxyHost}');
    }
    addRow(
      '方式',
      _methodText(info),
      valueColor: info.outcome == AdFilterOutcome.filtered
          ? palette.success
          : palette.warning,
    );
    if (info.sourceDuration > 0) {
      final filtered = info.filteredDuration;
      addRow('片长',
          '${_clock(info.sourceDuration)}${filtered > 0 && (filtered - info.sourceDuration).abs() >= 0.5 ? ' → ${_clock(filtered)}' : ''}');
    }
    if (info.shiftedStart != null) {
      addRow('续播点', '已换算到 ${_clock(info.shiftedStart!.inMilliseconds / 1000)}');
    }
    if (info.reason != null && info.reason!.isNotEmpty) {
      addRow('说明', info.reason!);
    }

    if (info.cuts.isNotEmpty) {
      rows.add(_sectionTitle(palette, '已删除 ${info.cuts.length} 段'));
      for (var i = 0; i < info.cuts.length; i++) {
        final cut = info.cuts[i];
        final tag = switch (cut.placement) {
          HlsAdPlacement.head => '（片头）',
          HlsAdPlacement.tail => '（片尾）',
          _ => '',
        };
        rows.add(Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            '#${i + 1}  ${_clock(cut.start)} – ${_clock(cut.end)}'
            '（${cut.duration.toStringAsFixed(1)}s）$tag',
            style: TextStyle(color: palette.playerText, fontSize: AppType.caption),
          ),
        ));
      }
    }

    if (info.hasAnalysis) {
      rows.add(_sectionTitle(palette, '分块 ${info.blocks.length} 个'));
      rows.add(Text(
        _blocksText(info.blocks),
        style: TextStyle(
            color: palette.playerText.withValues(alpha: 0.86),
            fontSize: AppType.caption,
            height: 1.5),
      ));
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text('图例：序号:块时长/分片数，★ = 判定为广告',
            style: TextStyle(
                color: palette.playerText.withValues(alpha: 0.5),
                fontSize: AppType.caption)),
      ));
    }

    rows.add(_sectionTitle(palette, '状态'));
    rows.add(StreamBuilder<Duration>(
      stream: widget.engine.positionStream,
      initialData: widget.engine.position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final total = info.filteredDuration > 0
            ? info.filteredDuration
            : info.sourceDuration;
        final tail = info.outcome == AdFilterOutcome.filtered
            ? '剪辑模式：列表里已无广告'
            : '原地址播放：${info.outcome.label}';
        return Text(
          '${_clock(position.inMilliseconds / 1000)}'
          '${total > 0 ? ' / ${_clock(total)}' : ''} · $tail',
          style: TextStyle(color: palette.playerText, fontSize: AppType.caption),
        );
      },
    ));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  Widget _buildFooter(AppPalette palette, AdFilterDebugInfo? info) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.sm),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: context.glassBorder.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'D 键开关 · 结论只对当前这一集有效',
              style: TextStyle(
                  color: palette.playerText.withValues(alpha: 0.45),
                  fontSize: AppType.caption),
            ),
          ),
          TextButton.icon(
            onPressed: info == null ? null : () => _copy(info),
            icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded,
                size: 14),
            label: Text(_copied ? '已复制' : '复制诊断',
                style: const TextStyle(fontSize: AppType.caption)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(AppPalette palette, String text) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: 2),
        child: Text(text,
            style: TextStyle(
                color: palette.playerText.withValues(alpha: 0.62),
                fontSize: AppType.caption,
                fontWeight: FontWeight.w600)),
      );

  String _methodText(AdFilterDebugInfo info) {
    if (info.outcome == AdFilterOutcome.filtered) {
      return '剪辑（删除 ${info.cutCount} 段 / '
          '${info.removedSeconds.toStringAsFixed(1)}s）';
    }
    if (info.fromMaster) return '主列表转发（按所选码率裁剪）';
    return info.outcome.label;
  }

  String _blocksText(List<HlsAdBlock> blocks) {
    final parts = <String>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      parts.add('$i:${block.duration.toStringAsFixed(0)}s/${block.segments}'
          '${block.isAd ? '★' : ''}');
    }
    return parts.join('  ');
  }

  static String _clock(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }
}
