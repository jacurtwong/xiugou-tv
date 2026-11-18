import 'dart:async';
import 'dart:convert';

import '../danmaku/danmaku_api.dart';
import '../net/http_client_factory.dart';
import 'playback_http_headers.dart';

/// 从播放页 HTML 里抠出真正的媒体地址。
///
/// 背景（用户 2026-11-19 反馈）：TV-西瓜资源 / TV-吉吉资源 / TV-非凡 / TV-电影天堂 这四个站
/// 的 `vod_play_url` 给的是**分享页**（`/share/…`、`/play/…`、`/watch/…`），
/// 真正的 `index.m3u8` 写在页面脚本里：
///
/// ```html
/// <script>
///   const url = "/20261023/43933_85b25f84/index.m3u8?sign=146a9b66727c5f9055c518e2e9136e4e";
/// </script>
/// ```
///
/// 这些站的 `needsParse` 是 0（它们自称直链），所以不会走解析引擎；结果 mpv 拿到 HTML，
/// 报 `Failed to recognize file format.`。这里做一个**本地解析**兜底：抓页面 → 抽地址 → 校验可用。
class PageMediaResolver {
  PageMediaResolver({this.cacheSize = 200, this.timeout = const Duration(seconds: 8)});

  final int cacheSize;
  final Duration timeout;
  final Map<String, String?> _cache = <String, String?>{};

  /// 解析 [pageUrl] 指向的播放页，返回可直接播放的媒体地址；解析不出来返回 null。
  ///
  /// [headers] 是站点自带的请求头（Referer / UA 等），会补上浏览器默认值再发。
  Future<String?> resolve(
    String pageUrl, {
    Map<String, String>? headers,
  }) async {
    if (_cache.containsKey(pageUrl)) return _cache[pageUrl];
    final uri = Uri.tryParse(pageUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final requestHeaders =
        withBrowserHeaderFallbacks(headers, pageUrl, enabled: true) ??
            const <String, String>{};
    final client = HttpClientFactory.createHttpClient(
      connectionTimeout: const Duration(seconds: 5),
      idleTimeout: HttpClientFactory.dioDefaultIdleTimeout,
      proxy: DanmakuApi.systemProxy,
    );
    String? found;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      requestHeaders.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final body = await response
            .transform(const Utf8Decoder(allowMalformed: true))
            .join()
            .timeout(timeout);
        found = extractMediaUrlFromHtml(body, uri);
      } else {
        // 错误页也要排空，否则连接不复用。
        await response.drain<void>().catchError((Object _) {});
      }
    } catch (_) {
      found = null;
    } finally {
      client.close(force: true);
    }
    _remember(pageUrl, found);
    return found;
  }

  void _remember(String key, String? value) {
    if (_cache.length >= cacheSize) _cache.remove(_cache.keys.first);
    _cache[key] = value;
  }

  void clear() => _cache.clear();
}

/// 纯函数：从页面 HTML 中抽媒体地址（相对地址按 [pageUri] 补全）。
///
/// 顺序：脚本里的 `url` 赋值 → 页面里任何绝对 m3u8/mp4 地址 → 任何相对 `*.m3u8` 路径。
/// 抽不到返回 null。抽出来的地址**不保证可播**，调用方应再做一次快速校验。
String? extractMediaUrlFromHtml(String html, Uri pageUri) {
  if (html.isEmpty) return null;

  // 1) const url = "..." / url: "..." / "url":"..."（分享页的常见写法）
  final assign = RegExp(
    r'''(?:const\s+url|url)\s*[:=]\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(html);
  final fromAssign = assign?.group(1);
  if (fromAssign != null && fromAssign.trim().isNotEmpty) {
    final abs = _absolute(fromAssign.trim(), pageUri);
    if (abs != null && _looksMedia(abs)) return abs;
  }

  // 2) 页面里写死的绝对地址（可能带反斜杠转义 `\/`）
  final absolute = RegExp(
    r'''https?:\\?/\\?/[^\s"'<>]+?\.(?:m3u8|mp4|flv|mkv)(?:\?[^\s"'<>]*)?''',
    caseSensitive: false,
  ).allMatches(html);
  for (final match in absolute) {
    final raw = match.group(0)!.replaceAll(r'\/', '/');
    if (_looksMedia(raw)) {
      return _absolute(raw, pageUri);
    }
  }

  // 3) 相对路径：/20261023/xxx/index.m3u8?sign=...
  final relative = RegExp(
    r'''["'](/[^\s"'<>]*?\.(?:m3u8|mp4|flv|mkv)(?:\?[^\s"'<>]*)?)["']''',
    caseSensitive: false,
  ).allMatches(html);
  for (final match in relative) {
    final abs = _absolute(match.group(1)!, pageUri);
    if (abs != null && _looksMedia(abs)) return abs;
  }
  return null;
}

bool _looksMedia(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  return path.endsWith('.m3u8') ||
      path.endsWith('.mp4') ||
      path.endsWith('.flv') ||
      path.endsWith('.mkv');
}

String? _absolute(String raw, Uri pageUri) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null) return null;
  if (parsed.hasScheme) return parsed.toString();
  if (trimmed.startsWith('//')) return '${pageUri.scheme}:$trimmed';
  return pageUri.resolveUri(parsed).toString();
}

/// 这个地址看起来像「分享页 / 播放页」而不是媒体直链吗？
///
/// 只有一眼能看出不是媒体（没有媒体后缀）才算；判断保守，宁可多试一次页面解析，
/// 也不要把能播的直链送去做无谓请求。
bool looksLikeSharePage(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final path = uri.path.toLowerCase();
  // 根路径没有"页面"含义，别当成分享页去抓。
  if (path.isEmpty || path == '/') return false;
  return !(path.endsWith('.m3u8') ||
      path.endsWith('.mp4') ||
      path.endsWith('.flv') ||
      path.endsWith('.mkv') ||
      path.endsWith('.ts') ||
      path.endsWith('.mpd'));
}
