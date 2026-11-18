import 'hls_ad_filter.dart';

/// 一次起播「广告剪辑」的结论分类（播放器调试面板直接展示）。
enum AdFilterOutcome {
  /// 已把插播片段剪掉，播放器拿到的是剪后列表。
  filtered('已剪辑'),

  /// 多码率主列表：真正裁剪发生在播放器选中的那一档，首跳时还不知道结果。
  master('多码率主列表'),

  /// 抓到了清单，但没有满足判定条件的短块。
  noAds('无插播广告'),

  /// 地址不是 .m3u8 / .m3u（不做任何请求）。
  notHls('非 HLS 地址'),

  /// 直播流（清单没有 ENDLIST），剪了必坏。
  live('直播流'),

  /// 带 `#EXT-X-BYTERANGE` 的清单：分片偏移绑在同一文件上，删块必坏。
  byteRange('字节范围清单'),

  /// 设置里关掉了「广告过滤」。
  disabled('开关已关闭'),

  /// 配了系统代理：本地清单会被 mpv 一起塞进代理，直接跳过。
  systemProxy('系统代理中'),

  /// 请求 / 解析失败（超时、非 2xx、内容不是清单……）。
  unavailable('拉取或解析失败');

  const AdFilterOutcome(this.label);
  final String label;
}

/// 「广告调试」面板的数据快照。
///
/// 由 `MpvPlayerEngine` 在每次起播时写入，播放器按 D 键打开面板读取。
/// 只保留**本集**的结论，换集 / 重新起播会覆盖；不放任何令牌或完整地址，
/// 只留主机名，方便截图反馈而不泄露源站参数。
class AdFilterDebugInfo {
  const AdFilterDebugInfo({
    required this.outcome,
    this.reason,
    this.title,
    this.sourceHost = '',
    this.proxyHost = '',
    this.cutCount = 0,
    this.removedSeconds = 0,
    this.sourceDuration = 0,
    this.filteredDuration = 0,
    this.blocks = const [],
    this.cuts = const [],
    this.fromMaster = false,
    this.shiftedStart,
    this.at,
  });

  final AdFilterOutcome outcome;

  /// 补充说明（失败原因、跳过原因）。
  final String? reason;

  /// 当前播放标题（`MediaPlaySpec.title`）。
  final String? title;

  /// 原始清单所在主机（不含路径与查询参数）。
  final String sourceHost;

  /// 本地代理主机（`127.0.0.1`）；未走代理时为空。
  final String proxyHost;

  /// 删掉的段数。
  final int cutCount;

  /// 删掉的总秒数。
  final double removedSeconds;

  /// 原始总时长（秒）。
  final double sourceDuration;

  /// 剪后总时长（秒）。
  final double filteredDuration;

  /// 每个 chunk 的时长 / 分片数 / 是否广告。
  final List<HlsAdBlock> blocks;

  /// 被删掉的区间（原始时间轴）。
  final List<HlsAdCut> cuts;

  final bool fromMaster;

  /// 续播点被换算到剪后时间轴时的新位置（未换算为空）。
  final Duration? shiftedStart;

  final DateTime? at;

  bool get hasAnalysis => blocks.isNotEmpty;

  /// 供「复制诊断」使用的纯文本。
  String toReportText() {
    final buffer = StringBuffer()
      ..writeln('[ad-filter] ${outcome.label}${fromMaster ? '（主列表）' : ''}')
      ..writeln('标题：${title ?? '未知'}')
      ..writeln('源主机：${sourceHost.isEmpty ? '—' : sourceHost}');
    if (proxyHost.isNotEmpty) buffer.writeln('代理：$proxyHost');
    if (sourceDuration > 0) {
      buffer.writeln('片长：${_durationText(sourceDuration)}'
          '${filteredDuration > 0 && filteredDuration != sourceDuration ? ' → ${_durationText(filteredDuration)}' : ''}');
    }
    if (cutCount > 0) {
      buffer.writeln('删除：$cutCount 段 / ${removedSeconds.toStringAsFixed(1)} 秒');
      for (var i = 0; i < cuts.length; i++) {
        final cut = cuts[i];
        buffer.writeln('  #${i + 1} ${_durationText(cut.start)}'
            ' – ${_durationText(cut.end)}（${cut.duration.toStringAsFixed(1)}s'
            '${cut.placement == HlsAdPlacement.tail ? '，片尾' : cut.placement == HlsAdPlacement.head ? '，片头' : ''}）');
      }
    }
    if (reason != null && reason!.isNotEmpty) buffer.writeln('说明：$reason');
    if (shiftedStart != null) {
      buffer.writeln('续播点：换算为 ${_durationText(shiftedStart!.inMilliseconds / 1000)}');
    }
    if (hasAnalysis) {
      final parts = <String>[];
      for (var i = 0; i < blocks.length; i++) {
        final block = blocks[i];
        parts.add('$i:${block.duration.toStringAsFixed(0)}s/${block.segments}'
            '${block.isAd ? '★' : ''}');
      }
      buffer.writeln('分块：${parts.join(' ')}');
      buffer.writeln('图例：序号:块时长/分片数，★=判定为广告');
    }
    return buffer.toString();
  }

  static String _durationText(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }
}
