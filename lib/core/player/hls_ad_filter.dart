/// HLS 播放列表「插播广告」识别与剪辑（纯函数，可单测）。
///
/// 算法移植自同维护者的另一款客户端 KimBoxPC（`server.js` 的
/// `analyzeAdRanges` / `buildCutPlaylist`），两边的判定阈值必须保持一致，
/// 否则同一部片在两个客户端上的表现会不一样。
///
/// 识别思路：插播广告的典型形态是
/// `正片块 | #EXT-X-DISCONTINUITY | 短广告块(5~90s / ≤30 片) | #EXT-X-DISCONTINUITY | 正片块`。
/// 因此按 discontinuity 切块，挑出「被两侧长正片夹住」的短块；片头 / 片尾广告没有两侧
/// 长正片，只在「分片数与时长特征」和已确认的插播广告完全一致时才认定，
/// 避免把片尾字幕、下集预告当广告切掉。
///
/// 三条硬性护栏（都来自实测，不要放宽）：
/// 1. 命中 >6 段、或广告总时长超过全片 5% → 大概率是「整集被切片」的正常封装，整体放弃；
/// 2. 含 `#EXT-X-BYTERANGE` 的列表不处理（分片偏移绑在同一个文件上，删块必坏）；
/// 3. 没有 `#EXT-X-ENDLIST` 的列表视为直播，不处理。
library;

import 'dart:math' as math;

/// 单块最多几家分片仍可能是广告（整集切片通常几十到几百片）。
const int kAdMaxSegments = 30;

/// 单块时长区间（秒）：短于 5 秒更像切片噪声，长于 90 秒不像贴片广告。
const double kAdMinDuration = 5;
const double kAdMaxDuration = 90;

/// 全片最多允许命中的广告块数；超过即判定为「整集切片」而放弃。
const int kAdMaxChunks = 6;

/// 广告总时长占全片的比例上限；超过即放弃。
const double kAdMaxTimeRatio = 0.05;

/// 剪辑时的二次护栏：只删「仍然像广告」的块（比识别条件略宽），宁可少删不误删。
const double kAdCutMinDuration = 5;
const double kAdCutMaxDuration = 120;
const int kAdCutMaxSegments = 40;

/// 广告块判定后是否被识别为片头 / 片尾。
enum HlsAdPlacement { middle, head, tail }

/// 播放列表里的一个 chunk（两个 discontinuity 之间的一段）。
class HlsAdBlock {
  const HlsAdBlock({
    required this.duration,
    required this.segments,
    required this.isAd,
    this.placement,
  });

  final double duration;
  final int segments;
  final bool isAd;

  /// 仅 [isAd] 为真时有值：插播 / 片头 / 片尾。
  final HlsAdPlacement? placement;

  HlsAdBlock copyWith({bool? isAd, HlsAdPlacement? placement}) => HlsAdBlock(
        duration: duration,
        segments: segments,
        isAd: isAd ?? this.isAd,
        placement: placement ?? this.placement,
      );

  @override
  String toString() =>
      'HlsAdBlock(${duration.toStringAsFixed(2)}s, $segments片${isAd ? ', 广告' : ''})';
}

/// 一段被判定为广告的区间（**原始时间轴**，秒）。
class HlsAdCut {
  const HlsAdCut({
    required this.start,
    required this.end,
    required this.placement,
  });

  final double start;
  final double end;
  final HlsAdPlacement placement;

  double get duration => end - start;

  @override
  String toString() => '${start.toStringAsFixed(1)}s-${end.toStringAsFixed(1)}s';
}

/// 一次分析的结果。位置信息只用于诊断与日志，剪辑不依赖它。
class HlsAdAnalysis {
  const HlsAdAnalysis({
    required this.blocks,
    required this.cuts,
    required this.duration,
    required this.mainDuration,
    required this.edgeAds,
    required this.rejected,
  });

  /// 全部 chunk（含判定结果），下标与播放列表切块顺序一致。
  final List<HlsAdBlock> blocks;

  /// 判定的广告区间，按起始时间升序。
  final List<HlsAdCut> cuts;

  /// 原始总时长（秒，按 `#EXTINF` 累加）。
  final double duration;

  /// 剪掉广告后的正片时长（秒）。
  final double mainDuration;

  /// 片头 + 片尾广告数量。
  final int edgeAds;

  /// 命中过多被判为「整集切片」而放弃。
  final bool rejected;

  bool get hasAds => cuts.isNotEmpty;

  @override
  String toString() => 'HlsAdAnalysis(${blocks.length}块, ${cuts.length}段广告, '
      '${duration.toStringAsFixed(0)}s→${mainDuration.toStringAsFixed(0)}s'
      '${rejected ? ', 已放弃' : ''})';
}

/// 剪辑后的播放列表与统计。
class HlsCutPlaylist {
  const HlsCutPlaylist({
    required this.playlist,
    required this.cuts,
    required this.removedSeconds,
  });

  final String playlist;
  final List<HlsAdCut> cuts;
  final double removedSeconds;
}

/// 播放列表是否是「媒体列表」（含分片）而非主列表。
bool isMediaPlaylistText(String text) =>
    RegExp(r'^#EXTINF', multiLine: true).hasMatch(text);

/// 是否是 master（多码率）播放列表。
bool isMasterPlaylistText(String text) =>
    RegExp(r'^#EXT-X-STREAM-INF', multiLine: true).hasMatch(text);

/// 是否收尾（点播完整列表）；没有它的按直播处理，不碰。
bool hasEndListText(String text) =>
    RegExp(r'^#EXT-X-ENDLIST', multiLine: true).hasMatch(text);

/// 是否使用字节范围（分片偏移绑在同一文件上，删块必坏）。
bool hasByteRangeText(String text) =>
    RegExp(r'^#EXT-X-BYTERANGE', multiLine: true).hasMatch(text);

/// 按 `#EXT-X-DISCONTINUITY` 切块；tag 行本身不属于任何一块。
List<List<String>> splitAdBlocks(String text) {
  final lines = text.split(RegExp(r'\r?\n'));
  final blocks = <List<String>>[];
  var current = <String>[];
  for (final line in lines) {
    if (RegExp(r'^#EXT-X-DISCONTINUITY', caseSensitive: false)
        .hasMatch(line.trim())) {
      blocks.add(current);
      current = <String>[];
    } else {
      current.add(line);
    }
  }
  blocks.add(current);
  return blocks;
}

/// 切块的行号区间（`[start, end)`），与 [splitAdBlocks] 顺序严格一致。
List<({int start, int end})> splitAdBlockRanges(String text) {
  final lines = text.split(RegExp(r'\r?\n'));
  final blocks = <({int start, int end})>[];
  var start = 0;
  for (var i = 0; i < lines.length; i++) {
    if (RegExp(r'^#EXT-X-DISCONTINUITY', caseSensitive: false)
        .hasMatch(lines[i].trim())) {
      blocks.add((start: start, end: i));
      start = i + 1;
    }
  }
  blocks.add((start: start, end: lines.length));
  return blocks;
}

({double duration, int segments}) _blockInfo(List<String> lines) {
  var duration = 0.0;
  var segments = 0;
  for (final raw in lines) {
    final line = raw.trim();
    if (!line.startsWith('#EXTINF')) continue;
    // #EXTINF:<时长>,[标题]；标题里可能有冒号，只取第一个冒号到第一个逗号。
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    var value = line.substring(colon + 1);
    final comma = value.indexOf(',');
    if (comma >= 0) value = value.substring(0, comma);
    duration += double.tryParse(value.trim()) ?? 0;
    segments++;
  }
  return (duration: duration, segments: segments);
}

bool _isAdShape(({double duration, int segments}) info) =>
    info.segments >= 1 &&
    info.segments <= kAdMaxSegments &&
    info.duration >= kAdMinDuration &&
    info.duration <= kAdMaxDuration;

String _signature(({double duration, int segments}) info) =>
    '${info.segments}:${info.duration.round()}';

List<HlsAdBlock> _blockList(
  List<({double duration, int segments})> infos,
  Map<int, HlsAdPlacement> adMap,
) =>
    List<HlsAdBlock>.generate(
      infos.length,
      (i) => HlsAdBlock(
        duration: infos[i].duration,
        segments: infos[i].segments,
        isAd: adMap.containsKey(i),
        placement: adMap[i],
      ),
      growable: false,
    );

/// 分析播放列表里的插播 / 片头 / 片尾广告。
HlsAdAnalysis analyzeAdBlocks(String text) {
  final blocks = splitAdBlocks(text);
  final infos = blocks.map(_blockInfo).toList(growable: false);
  final totalDuration = infos.fold<double>(0, (sum, info) => sum + info.duration);

  // 不足 3 块不可能存在「夹在正片中间」的插播；但片长照常返回（面板要显示）。
  if (blocks.length < 3) {
    return HlsAdAnalysis(
      blocks: _blockList(infos, const {}),
      cuts: const [],
      duration: totalDuration,
      mainDuration: totalDuration,
      edgeAds: 0,
      rejected: false,
    );
  }

  final picked = <int>[];
  for (var i = 1; i < blocks.length - 1; i++) {
    if (!_isAdShape(infos[i])) continue;
    // 相邻两块不重复命中：一组广告常被拆成两个短块。
    if (picked.contains(i - 1)) continue;
    final need = math.max(180.0, infos[i].duration * 3);
    final left = infos[i - 1];
    final right = infos[i + 1];
    if (left.segments <= 0 || left.duration < need) continue;
    if (right.segments <= 0 || right.duration < need) continue;
    picked.add(i);
  }

  final adDuration = picked.fold<double>(0, (sum, i) => sum + infos[i].duration);
  if (picked.length > kAdMaxChunks || adDuration > totalDuration * kAdMaxTimeRatio) {
    // 命中太多或占比太高：更像「整集被切片」，宁可不剪。
    return HlsAdAnalysis(
      blocks: _blockList(infos, const {}),
      cuts: const [],
      duration: totalDuration,
      mainDuration: totalDuration,
      edgeAds: 0,
      rejected: true,
    );
  }

  // 先把「中间插播 + 片头 / 片尾」的广告集合定下来，再算时间轴位置。
  final adMap = <int, HlsAdPlacement>{
    for (final index in picked) index: HlsAdPlacement.middle,
  };

  // 片头 / 片尾：只有「分片数 + 时长」与已确认的插播广告完全一致才认定。
  final adSignatures = picked.map((i) => _signature(infos[i])).toSet();
  var edgeAds = 0;
  if (blocks.length >= 2 && adSignatures.isNotEmpty) {
    final last = blocks.length - 1;
    if (_isAdShape(infos[0]) &&
        adSignatures.contains(_signature(infos[0])) &&
        infos[1].duration >= math.max(180.0, infos[0].duration * 3)) {
      adMap[0] = HlsAdPlacement.head;
      edgeAds++;
    }
    if (_isAdShape(infos[last]) &&
        adSignatures.contains(_signature(infos[last])) &&
        infos[last - 1].duration >= math.max(180.0, infos[last].duration * 3)) {
      adMap[last] = HlsAdPlacement.tail;
      edgeAds++;
    }
  }

  // 正片分片在源视频里是连续编码的（PTS 从 0 递增，不含插播时长），
  // 所以广告在「原始时间轴」上的位置 = 它前面所有正片块时长之和。
  // 这里用**最终**广告集合累加，片头广告也要排除，否则后面的位置整体前移一段。
  final blockStarts = List<double>.filled(blocks.length, 0);
  var dramaAccumulator = 0.0;
  for (var i = 0; i < blocks.length; i++) {
    blockStarts[i] = dramaAccumulator;
    if (!adMap.containsKey(i)) dramaAccumulator += infos[i].duration;
  }

  final cuts = <HlsAdCut>[
    for (final entry in adMap.entries)
      HlsAdCut(
        start: blockStarts[entry.key],
        end: blockStarts[entry.key] + infos[entry.key].duration,
        placement: entry.value,
      ),
  ]..sort((a, b) => a.start.compareTo(b.start));

  return HlsAdAnalysis(
    blocks: _blockList(infos, adMap),
    cuts: cuts,
    duration: totalDuration,
    mainDuration: dramaAccumulator,
    edgeAds: edgeAds,
    rejected: false,
  );
}

/// 「剪辑」：把判定为广告的块整块删掉，重新生成一份干净列表。
///
/// 拼接处保留一个 `#EXT-X-DISCONTINUITY`：分片是从不同时间点切开的，
/// 没有它播放器会按原 PTS 衔接而出现跳帧 / 时间轴错乱。
/// ffmpeg 的 hls 解复用器会把跨越 discontinuity 的时间戳归一化，
/// 所以播放器看到的时间轴是**剪后**的连续时长，进度条与续播点都据此记录。
///
/// ⚠️ 切块方式必须与 [analyzeAdBlocks] 完全一致（表头留在第 0 块），
/// 否则 `analysis.blocks` 的广告标记会整体错位，把正片当广告删掉。
HlsCutPlaylist buildCutPlaylist(String text, HlsAdAnalysis analysis) {
  final lines = text.split(RegExp(r'\r?\n'));
  final ranges = splitAdBlockRanges(text);
  final hadEndList = hasEndListText(text);

  bool safeToCut(int index) {
    if (index < 0 || index >= analysis.blocks.length) return false;
    final block = analysis.blocks[index];
    if (!block.isAd) return false;
    return block.duration >= kAdCutMinDuration &&
        block.duration <= kAdCutMaxDuration &&
        block.segments <= kAdCutMaxSegments;
  }

  final out = <String>[];
  final cuts = <HlsAdCut>[];
  var cursor = 0.0;
  var removed = 0.0;
  var kept = 0;

  for (var index = 0; index < ranges.length; index++) {
    final range = ranges[index];
    var duration = 0.0;
    for (var i = range.start; i < range.end; i++) {
      duration += _blockInfo(<String>[lines[i]]).duration;
    }
    final start = cursor;
    cursor += duration;

    if (safeToCut(index)) {
      cuts.add(HlsAdCut(
        start: start,
        end: cursor,
        placement: analysis.blocks[index].placement ?? HlsAdPlacement.middle,
      ));
      removed += duration;
      // 第 0 块被整体删掉时，表头（#EXTM3U / 版本 / TARGETDURATION…）仍要保留。
      if (index == 0) {
        for (var i = range.start; i < range.end; i++) {
          if (lines[i].trim().startsWith('#EXTINF')) break;
          out.add(lines[i]);
        }
      }
      continue;
    }

    // 块与块之间原本就有 discontinuity；剪掉中间块后仍要保留分界。
    if (kept > 0) out.add('#EXT-X-DISCONTINUITY');
    // ENDLIST 统一在末尾补一次，避免重复或落进被删的块里。
    for (var i = range.start; i < range.end; i++) {
      if (RegExp(r'^#EXT-X-ENDLIST', caseSensitive: false)
          .hasMatch(lines[i].trim())) {
        continue;
      }
      out.add(lines[i]);
    }
    kept++;
  }

  if (hadEndList) out.add('#EXT-X-ENDLIST');

  return HlsCutPlaylist(
    playlist: '${out.join('\n')}\n',
    cuts: cuts,
    removedSeconds: _round2(removed),
  );
}

double _round2(double value) => (value * 100).roundToDouble() / 100;

/// 把「原始时间轴」的续播点换算成剪后时间轴上的位置。
///
/// 剪掉的是广告，用户上次看到的位置不该跟着前移：
/// - 完全落在某个被剪区间之前 → 减去该区间时长；
/// - 落在被剪区间内 → 退到该区间起点（用户看的是广告，重看正片开头更合理）；
/// - 之后同理累加。
Duration? shiftStartAfterCut(Duration? start, List<HlsAdCut> cuts) {
  if (start == null || cuts.isEmpty) return start;
  final seconds = start.inMilliseconds / Duration.millisecondsPerSecond;
  var removed = 0.0;
  for (final cut in cuts) {
    if (cut.end <= seconds) {
      removed += cut.duration;
      continue;
    }
    if (cut.start < seconds) removed += seconds - cut.start;
    break;
  }
  final shifted = seconds - removed;
  return Duration(
      milliseconds: ((shifted < 0 ? 0 : shifted) * 1000).round());
}

/// 把播放列表里的相对地址改成绝对地址（分片行 + `URI="..."` 标签 + master 变体行）。
///
/// 交给我们自己的本地代理之后，播放器的相对地址基准变成了 `127.0.0.1`，
/// 不绝对化就一个分片都拉不到。
String absolutizePlaylist(String text, Uri base) {
  String toAbsolute(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return raw;
    if (RegExp(r'^(https?:)?//', caseSensitive: false).hasMatch(value)) return raw;
    if (value.startsWith('data:')) return raw;
    try {
      return base.resolve(value).toString();
    } catch (_) {
      return raw;
    }
  }

  final out = <String>[];
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      out.add('');
      continue;
    }
    if (trimmed.startsWith('#')) {
      // #EXT-X-KEY / #EXT-X-MAP / #EXT-X-MEDIA / #EXT-X-I-FRAME-STREAM-INF 里的 URI
      out.add(line.replaceAllMapped(
        RegExp('URI="([^"]*)"'),
        (match) => 'URI="${toAbsolute(match.group(1) ?? '')}"',
      ));
      continue;
    }
    out.add(toAbsolute(trimmed));
  }
  return out.join('\n');
}

/// 取出 master 列表里的每个变体地址（按出现顺序，已按 [base] 解析）。
List<Uri> masterVariantUris(String text, Uri base) {
  final uris = <Uri>[];
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    try {
      final uri = base.resolve(trimmed);
      if (uri.scheme == 'http' || uri.scheme == 'https') uris.add(uri);
    } catch (_) {
      // 解析不了的变体行直接跳过，不阻断其它变体。
    }
  }
  return uris;
}

/// 把 master 列表里的每个变体行替换成 [replace] 给出的本地地址。
///
/// 只改「变体行」与 `#EXT-X-I-FRAME-STREAM-INF` 的 URI；
/// `#EXT-X-MEDIA`（音轨 / 字幕）、`#EXT-X-KEY`、`#EXT-X-MAP` 保持绝对地址直连，
/// 这些子清单里没有插播广告，没必要绕一圈。
String rewriteMasterVariants(
  String text,
  Uri base,
  String Function(Uri variant, int index) replace,
) {
  final out = <String>[];
  var index = 0;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      if (trimmed.startsWith('#EXT-X-I-FRAME-STREAM-INF')) {
        out.add(line.replaceAllMapped(RegExp('URI="([^"]*)"'), (match) {
          final raw = match.group(1) ?? '';
          final absolute = base.resolve(raw).toString();
          return 'URI="${replace(Uri.parse(absolute), index++)}"';
        }));
        continue;
      }
      out.add(line);
      continue;
    }
    try {
      out.add(replace(base.resolve(trimmed), index++));
    } catch (_) {
      out.add(line);
    }
  }
  return out.join('\n');
}
