import 'package:package_info_plus/package_info_plus.dart';

/// 程序显示名：窗口标题、关于页、侧栏、安装器统一用它。
///
/// 2026-11-18 起改为**社区魔改版**，与上游 `qfw66/xiugou-tv` 明确区分；
/// 内部标识（exe 名 `xiugou_tv`、安装器 AppId、数据目录 `XiugouTV`）保持不变，
/// 否则升级安装、历史与备份都会对不上。
const String appDisplayName = '修狗TV（魔改版）';

/// 窄位置（侧栏）用的短名。
const String appShortName = '修狗TV';

/// 版本号后缀：只出现在显示名旁边，不参与版本比较。
const String appEditionLabel = '魔改版';

/// 构建注入的应用版本（`package_info_plus` 读取 exe 版本资源），供备份等
/// 非 UI 路径使用；未加载或读取失败时为 null（调用方兜底为「未知版本」）。
String? appVersionLabel;

/// 读取并缓存版本号；失败时保持 null（不写占位版本）。
///
/// 只取 `version`，不拼 build 号：build 号是构建自增标记，不参与更新判断
/// （`AppVersion.tryParse` 会丢弃 `+` 后缀），展示出来只会造成歧义。
Future<String?> loadAppVersionLabel() async {
  try {
    final info = await PackageInfo.fromPlatform();
    appVersionLabel = info.version;
  } catch (_) {
    appVersionLabel = null;
  }
  return appVersionLabel;
}
