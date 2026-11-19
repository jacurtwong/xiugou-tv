import 'models/vod_models.dart';

/// 自动模式（配置里没写 `categories`）下，按名字直接隐藏的分类。
///
/// 用户口径（2026-11-19，多轮追加）：体育类、伦理/擦边类，以及「电影 / 动漫 / 综艺 /
/// 连续剧」这类大而全的总目录都不该出现在分类条上——要么没内容、要么内容杂且重复多。
/// 配置里显式写了 `categories` 时**不受这里影响**（白名单优先，用户自己说了算）。
const List<String> autoHiddenCategoryKeywords = <String>[
  // 体育
  '体育', '运动', '足球', '篮球', '网球', '斯诺克', '台球', '赛事',
  '羽毛球', '乒乓', '赛车', '搏击', '拳击', '电竞', '棋牌',
  // 伦理 / 擦边
  '伦理', '成人', '情色', '里番', '福利', '擦边', '三级', '两性', '写真',
  // 大而全的总目录（用户明确要求整类隐藏）
  '电影', '动漫', '综艺', '连续剧',
];

String _normalizeCategoryName(String value) =>
    value.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// 这个分类名在自动模式下是否应当隐藏。
bool isAutoHiddenCategoryName(String name) {
  final normalized = _normalizeCategoryName(name);
  if (normalized.isEmpty) return false;
  for (final keyword in autoHiddenCategoryKeywords) {
    if (normalized.contains(_normalizeCategoryName(keyword))) return true;
  }
  return false;
}

/// 自动模式下的分类过滤：按名字隐藏上面那些关键词。
///
/// 空数据分类没法在本地判断（要真请求一次才知道），由 UI 层在探测到空结果后
/// 追加隐藏，见 `_probeEmptyCategories`。
List<VodCategory> filterAutoCategories(List<VodCategory> categories) {
  if (categories.isEmpty) return const <VodCategory>[];
  final kept = categories
      .where((cat) => !isAutoHiddenCategoryName(cat.name))
      .toList(growable: false);
  // 全被隐藏了就退回原列表，别把分类条搞空。
  return List<VodCategory>.unmodifiable(kept.isEmpty ? categories : kept);
}
