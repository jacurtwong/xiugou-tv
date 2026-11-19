import 'models/vod_models.dart';

/// 按站点配置里的 `categories` 决定显示哪些分类、以什么顺序（用户 2026-11-19 口径）。
///
/// - 配置里没写 `categories`（或为空）→ 原样返回，保持站点/接口给的顺序（自动）；
/// - 配置里写了 → **只显示配置里列出的分类**，并严格按配置顺序：
///   逐个在接口返回的分类里找（先精确同名，再互相包含）；接口多出来的分类不显示；
/// - 配置里的名字一个都没匹配上时，退回接口原始列表（避免配置写错导致分类条整个空掉）。
///
/// 只做筛选与排序，不改 name/id；匹配用去空白 + 小写，避免全半角 / 大小写差异。
List<VodCategory> orderCategoriesBySite(
  List<VodCategory> fetched,
  List<String>? preferred,
) {
  if (fetched.isEmpty) return const <VodCategory>[];
  if (preferred == null || preferred.isEmpty) {
    return List<VodCategory>.unmodifiable(fetched);
  }
  String norm(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  final remaining = List<VodCategory>.of(fetched);
  final ordered = <VodCategory>[];
  for (final rawName in preferred) {
    final name = norm(rawName);
    if (name.isEmpty) continue;
    var index = remaining.indexWhere((cat) => norm(cat.name) == name);
    if (index < 0) {
      index = remaining.indexWhere((cat) {
        final catName = norm(cat.name);
        return catName.contains(name) || name.contains(catName);
      });
    }
    if (index < 0) continue;
    ordered.add(remaining.removeAt(index));
  }
  // 配置里的分类一个都没匹配上：退回接口原始列表，别把界面搞空。
  if (ordered.isEmpty) return List<VodCategory>.unmodifiable(fetched);
  return List<VodCategory>.unmodifiable(ordered);
}
