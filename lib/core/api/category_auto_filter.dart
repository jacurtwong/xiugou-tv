import '../config/models/vod_config.dart';
import 'models/vod_models.dart';

/// 自动模式（配置里没写 `categories`）下要隐藏的分类名——**精确匹配**。
///
/// 维护者口径（2026-11-19，多次修正后定稿）：只隐藏名单里这些名字，
/// 不做「包含」模糊匹配。所以 `电影` 被隐藏，而 `4K电影`、`电影片` 之外的
/// `国产动漫`、`大陆综艺` 都不受影响。
const Set<String> autoHiddenCategoryNames = <String>{
  // 大而全的总目录
  '电影', '电影片', '连续剧', '电视剧', '动漫', '动漫片', '综艺', '综艺片',
  // 伦理 / 擦边
  '伦理', '伦理片', '倫理片', '理论片', '韩国伦理', '西方伦理', '日本伦理',
  '成人', '情色', '里番', '三级', '港台三级',
  '两性', '两性课堂', '写真', '写真热舞', '擦边', '擦边剧', '擦边短剧', '福利',
  // 体育
  '体育', '体育赛事', '运动', '赛事', '足球', '篮球', '网球', '斯诺克',
  '台球', '羽毛球', '乒乓球', '乒乓', '赛车', '搏击', '拳击', '电竞', '棋牌',
};

String _normalizeCategoryName(String value) =>
    value.replaceAll(RegExp(r'\s+'), '').toLowerCase();

final Set<String> _normalizedHiddenNames = {
  for (final name in autoHiddenCategoryNames) _normalizeCategoryName(name),
};

/// 这个分类名在自动模式下是否应当隐藏（**精确匹配**，不是包含）。
bool isAutoHiddenCategoryName(String name) {
  final normalized = _normalizeCategoryName(name);
  if (normalized.isEmpty) return false;
  return _normalizedHiddenNames.contains(normalized);
}

/// 自动模式下的分类过滤：只按上面的**精确名单**隐藏。
///
/// **只对 CMS/JSON 站生效**：spider 站（csp jar / js / py / type=3）的分类是站点自己声明的，
/// 用户 2026-11-19 明确要求「csp 不要过滤」，所以这里原样返回。
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

/// 按站点类型决定要不要过滤：**spider 站（csp jar / js / py）一律不过滤**。
List<VodCategory> filterAutoCategoriesForSite(
  Site site,
  List<VodCategory> categories,
) {
  if (site.usesCompanion) return categories;
  return filterAutoCategories(categories);
}
