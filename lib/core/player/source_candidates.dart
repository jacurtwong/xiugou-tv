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

/// 选集抽屉「其他来源」的自动搜索结果。
///
/// 与换源对话框的区别只在**排序**：对话框按匹配度（`score`）排，
/// 这里按延迟（`latencyMs`）升序——用户点开选集时想知道的是「哪个源快」。
class SourceCandidatesState {
  const SourceCandidatesState({
    this.searching = false,
    this.searched = false,
    this.candidates = const <CrossSiteCandidate>[],
    this.message,
    this.episodeKey,
  });

  /// 正在跨站搜索。
  final bool searching;

  /// 至少完成过一次搜索（用于区分「还没搜」与「搜了但没有」）。
  final bool searched;

  /// 按延迟升序排好的候选。
  final List<CrossSiteCandidate> candidates;

  /// 没结果时的说明（超时 / 失败 / 没有可信同片同集）。
  final String? message;

  /// 本批结果对应的集（集变名 / 换集后旧结果作废）。
  final String? episodeKey;

  bool get hasCandidates => candidates.isNotEmpty;
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
