import '../api/models/vod_models.dart';
import 'cross_site_failover_planner.dart';

/// 解析候选时的一条线路尝试（线路 + 该线路里对得上的一集）。
class CrossSiteResolveAttempt {
  const CrossSiteResolveAttempt({
    required this.lineIndex,
    required this.lineName,
    required this.episode,
    required this.episodeIndex,
  });

  final int lineIndex;
  final String lineName;
  final VodEpisode episode;
  final int episodeIndex;
}

/// 解析候选时的线路尝试顺序：候选选中的线路优先，其次同站其它线路里「同名同集」的。
///
/// 一个站点常有多条线路（`PlayFrom`），候选只挑了最匹配的一条；那条需要解析 /
/// 解析失效时，同站其它线路往往还能播。默认最多试 3 条，避免「换源」卡一分钟以上。
List<CrossSiteResolveAttempt> resolveLineAttempts(
  CrossSiteCandidate candidate, {
  int maxAttempts = 3,
}) {
  final attempts = <CrossSiteResolveAttempt>[
    CrossSiteResolveAttempt(
      lineIndex: candidate.sourceIndex,
      lineName: candidate.source.name,
      episode: candidate.episodeMatch.episode,
      episodeIndex: candidate.episodeMatch.episodeIndex,
    ),
  ];
  final targetName = candidate.episodeMatch.episode.name;
  final sources = candidate.detail.sources;
  for (var i = 0; i < sources.length && attempts.length < maxAttempts; i++) {
    if (i == candidate.sourceIndex) continue;
    final source = sources[i];
    var index = -1;
    for (var j = 0; j < source.episodes.length; j++) {
      if (source.episodes[j].name == targetName) {
        index = j;
        break;
      }
    }
    if (index < 0) continue;
    attempts.add(CrossSiteResolveAttempt(
      lineIndex: i,
      lineName: source.name,
      episode: source.episodes[index],
      episodeIndex: index,
    ));
  }
  return attempts;
}

/// 一条来源的**可播性体检**结果（照 KimBoxPC `/api/sites/ping` + `probeMedia` 的思路）：
/// 真的去解析一次该线路、再看返回的是不是媒体，而不是只相信搜索时的耗时。
class SourceProbe {
  const SourceProbe({required this.ok, required this.ms, this.reason});

  final bool ok;

  /// 从发起解析到拿到可播地址的毫秒数（失败时为耗时）。
  final int ms;

  /// 失败原因（`网页直链` / `解析超时` / 具体异常首行）。
  final String? reason;
}

/// 候选的身份键（站点 + 线路），用于把体检结果对回列表项。
String sourceCandidateKey(CrossSiteCandidate candidate) =>
    '${candidate.site.key}::${candidate.source.name}';

/// 展示排序（照 KimBoxPC 的 `rank` 思路）：
/// 1. 体检可播的排最前，按体检耗时升序；
/// 2. 还没测到的排中间，按搜索延迟升序；
/// 3. 体检失败（网页直链 / 超时 / 报错）排最后，按搜索延迟升序。
List<CrossSiteCandidate> sortCandidatesByProbe(
  Iterable<CrossSiteCandidate> input,
  Map<String, SourceProbe> probes,
) {
  final indexed = <(int, CrossSiteCandidate)>[
    for (var i = 0; i < input.length; i++) (i, input.elementAt(i)),
  ];
  int rank(CrossSiteCandidate candidate, SourceProbe? probe) {
    if (probe == null) return 1;
    return probe.ok ? 0 : 2;
  }

  int latency(CrossSiteCandidate candidate, SourceProbe? probe) {
    if (probe != null && probe.ok) return probe.ms;
    if (candidate.latencyMs <= 0) return 1 << 30;
    return candidate.latencyMs;
  }

  indexed.sort((a, b) {
    final pa = probes[sourceCandidateKey(a.$2)];
    final pb = probes[sourceCandidateKey(b.$2)];
    final byRank = rank(a.$2, pa).compareTo(rank(b.$2, pb));
    if (byRank != 0) return byRank;
    final byLatency = latency(a.$2, pa).compareTo(latency(b.$2, pb));
    return byLatency != 0 ? byLatency : a.$1.compareTo(b.$1);
  });
  return List<CrossSiteCandidate>.unmodifiable(
      [for (final entry in indexed) entry.$2]);
}

/// 跨站搜索的缓存键：**整部剧一次搜索**，换集只换集名（用户 2026-11-19 口径）。
///
/// 用「规范化片名 + 集数」而不是 item.id：换源后 item 来自别的站点，id 必然不同，
/// 但片名一样、集数一样就该复用同一批来源。
String sourceCandidatesShowKey(VodItem item, int episodeCount) {
  final name = item.name.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  return '$name::$episodeCount';
}

/// 把候选映射到「当前这一集」：在候选的详情里按集名找同名集。
///
/// 候选本身记录的是**搜索时那一集**的地址；用户换集后如果直接用它，会跳到错误的集。
/// 找不到同名集时退回候选自带的匹配（宁可给出可点的一条，也不要整块消失）。
List<CrossSiteResolveAttempt> resolveAttemptsForEpisode(
  CrossSiteCandidate candidate,
  String? episodeName, {
  int maxAttempts = 3,
}) {
  final target = episodeName?.trim() ?? '';
  if (target.isEmpty) return resolveLineAttempts(candidate, maxAttempts: maxAttempts);

  final attempts = <CrossSiteResolveAttempt>[];
  final sources = candidate.detail.sources;
  // 候选线路优先，其余线路按配置顺序补；只在同一集里找。
  final order = <int>[
    if (candidate.sourceIndex >= 0 && candidate.sourceIndex < sources.length)
      candidate.sourceIndex,
    for (var i = 0; i < sources.length; i++)
      if (i != candidate.sourceIndex) i,
  ];
  for (final lineIndex in order) {
    if (attempts.length >= maxAttempts) break;
    final source = sources[lineIndex];
    var index = -1;
    for (var j = 0; j < source.episodes.length; j++) {
      if (source.episodes[j].name.trim() == target) {
        index = j;
        break;
      }
    }
    if (index < 0) continue;
    attempts.add(CrossSiteResolveAttempt(
      lineIndex: lineIndex,
      lineName: source.name,
      episode: source.episodes[index],
      episodeIndex: index,
    ));
  }
  return attempts.isEmpty
      ? resolveLineAttempts(candidate, maxAttempts: maxAttempts)
      : attempts;
}

/// 选集抽屉「其他来源」的自动搜索结果。
///
/// 与换源对话框的区别只在**排序**：对话框按匹配度（`score`）排，
/// 这里按延迟（`latencyMs`）升序——用户点开选集时想知道的是「哪个源快」。
class SourceCandidatesState {
  const SourceCandidatesState({
    this.searching = false,
    this.searched = false,
    this.candidates = const <CrossSiteCandidate>[],
    this.probes = const <String, SourceProbe>{},
    this.message,
    this.episodeKey,
  });

  /// 正在跨站搜索。
  final bool searching;

  /// 至少完成过一次搜索（用于区分「还没搜」与「搜了但没有」）。
  final bool searched;

  /// 按体检结果 + 延迟排好序的候选。
  final List<CrossSiteCandidate> candidates;

  /// 每个候选的可播性体检结果（key 见 [sourceCandidateKey]）。
  final Map<String, SourceProbe> probes;

  /// 没结果时的说明（超时 / 失败 / 没有可信同片同集）。
  final String? message;

  /// 本批结果对应的集（集变名 / 换集后旧结果作废）。
  final String? episodeKey;

  bool get hasCandidates => candidates.isNotEmpty;

  SourceProbe? probeFor(CrossSiteCandidate candidate) =>
      probes[sourceCandidateKey(candidate)];

  SourceCandidatesState copyWith({
    List<CrossSiteCandidate>? candidates,
    Map<String, SourceProbe>? probes,
    String? message,
  }) =>
      SourceCandidatesState(
        searching: searching,
        searched: searched,
        candidates: candidates ?? this.candidates,
        probes: probes ?? this.probes,
        message: message ?? this.message,
        episodeKey: episodeKey,
      );
}

/// 按延迟升序排列；未测到延迟（0）的排最后，同延迟保持传入顺序（稳定排序）。
List<CrossSiteCandidate> sortCandidatesByLatency(
    Iterable<CrossSiteCandidate> input) {
  final indexed = <(int, CrossSiteCandidate)>[
    for (var i = 0; i < input.length; i++) (i, input.elementAt(i)),
  ];
  int rank(CrossSiteCandidate candidate) =>
      candidate.latencyMs <= 0 ? 1 << 30 : candidate.latencyMs;
  indexed.sort((a, b) {
    final latency = rank(a.$2).compareTo(rank(b.$2));
    return latency != 0 ? latency : a.$1.compareTo(b.$1);
  });
  return List<CrossSiteCandidate>.unmodifiable(
      [for (final entry in indexed) entry.$2]);
}

/// 延迟文案：`123ms` / `1.2s`。
String formatLatency(int milliseconds) {
  if (milliseconds <= 0) return '—';
  if (milliseconds < 1000) return '${milliseconds}ms';
  return '${(milliseconds / 1000).toStringAsFixed(1)}s';
}
