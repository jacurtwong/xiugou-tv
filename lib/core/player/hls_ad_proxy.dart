/// 插播广告剪辑用的**本地播放列表代理**。
///
/// 为什么必须有它（实测结论，别绕过）：部分 CDN 每次请求返回的插播广告都不一样
/// （同一地址连拉 4 次得到 4 组不同的时长序列）。如果先分析、再让播放器直接拉原地址，
/// 分析和播放用的就不是同一份字节，剪出来的时间轴必然错位。
/// 所以这里**自己拉一次**，分析、剪辑、交给播放器，全程复用同一份文本。
///
/// 只代理**播放列表**，分片地址在首跳就被改写成绝对地址，由播放器直连 CDN——
/// 不转发分片，不占内存、不打乱 Range 请求与计费。
///
/// 主列表（多码率）按变体逐个换成子 token：播放器选哪档就临时分析哪档，
/// 因此不会因为「取第一个变体」而丢掉清晰度选择。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ad_filter_debug.dart';
import 'hls_ad_filter.dart';
import 'hls_playlist_probe.dart';

/// 一次过滤的结果（`url` 就是交给播放器的本地地址）。
class HlsAdFilterResult {
  const HlsAdFilterResult({
    required this.url,
    required this.fromMaster,
    this.cut,
    this.analysis,
  });

  /// 交给播放器的本地地址（`http://127.0.0.1:<port>/p/<token>.m3u8`）。
  final String url;

  /// 是否经过 master 列表转发。
  final bool fromMaster;

  /// 本档的剪后列表（主列表首跳时为 null，真正裁剪发生在变体请求时）。
  final HlsCutPlaylist? cut;

  /// 本档的分析结果（调试面板用）。
  final HlsAdAnalysis? analysis;

  int get cutCount => cut?.cuts.length ?? 0;

  double get removedSeconds => cut?.removedSeconds ?? 0;

  List<HlsAdCut> get cuts => cut?.cuts ?? const [];
}

/// 一次「要不要剪辑」的尝试结论。
///
/// **永远有值**：即使不剪也要带原因，播放器的「广告调试」面板靠它解释
/// 「为什么这一集没剪」——返回 null 的接口做不到这件事。
class HlsAdFilterAttempt {
  const HlsAdFilterAttempt(this.outcome, {this.result, this.reason});

  final AdFilterOutcome outcome;
  final HlsAdFilterResult? result;
  final String? reason;

  /// 非空表示调用方应改用本地地址。
  String? get url => result?.url;
}

class _Entry {
  _Entry.body(this.body, {required this.contentType})
      : source = null,
        headers = const {};

  _Entry.variant({required Uri this.source, required this.headers})
      : body = null,
        contentType = 'application/vnd.apple.mpegurl';

  /// 已生成的播放列表正文；主列表 / 已剪辑的媒体列表在创建时就有值。
  String? body;
  String contentType;

  /// 变体地址（懒分析用）。
  final Uri? source;
  final Map<String, String> headers;

  final DateTime createdAt = DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(createdAt) > HlsAdFilterProxy.cacheTtl;
}

/// 本地播放列表代理（**单例式使用**：由 `MpvPlayerEngine` 持有一份）。
///
/// 生命周期：第一次真正需要过滤时懒启动 `HttpServer`（绑定回环地址、随机端口），
/// 播放器关闭时 [shutdown]。启动失败、超时、非 HLS、直播、无广告都会返回 `null`，
/// 调用方按原地址播放——**广告过滤永远不能挡住起播**。
class HlsAdFilterProxy {
  HlsAdFilterProxy({HlsPlaylistFetch? fetch})
      : _fetch = fetch ?? fetchHlsPlaylist;

  static const Duration cacheTtl = Duration(hours: 6);
  static const int maxEntries = 64;

  /// 单跳预算：清单只有几十 KB，4 秒足够；**起播延迟上限**也由它决定。
  static const HlsFetchBudget fetchBudget = HlsFetchBudget(
    maxBytes: 2 << 20,
    timeout: Duration(seconds: 4),
  );

  final HlsPlaylistFetch _fetch;
  final Map<String, _Entry> _entries = {};
  HttpServer? _server;
  int _counter = 0;
  bool _closed = false;

  /// 当前监听端口（未启动时为 null），仅用于诊断与测试。
  int? get port => _server?.port;

  /// 尝试把 [url] 换成「已剪掉插播广告」的本地播放列表地址。
  ///
  /// 返回值永远非空：`url` 非空时调用方应使用它，否则按原地址播放。
  /// 不剪辑的原因写进 [HlsAdFilterAttempt.reason]，供调试面板展示。
  Future<HlsAdFilterAttempt> filter(
    String url,
    Map<String, String> headers,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return const HlsAdFilterAttempt(AdFilterOutcome.notHls);
    }
    if (_closed) {
      return const HlsAdFilterAttempt(AdFilterOutcome.unavailable,
          reason: '本地代理已关闭');
    }
    // 只看自己的地址：局域网 / 本机 HLS 源照常过滤，但绝不把自己的播放列表再喂回来。
    if (_isLoopback(uri) && uri.port == (_server?.port ?? -1)) {
      return const HlsAdFilterAttempt(AdFilterOutcome.unavailable,
          reason: '目标地址就是本地代理本身');
    }

    final HlsFetchResponse response;
    try {
      response = await _fetch(uri, headers, fetchBudget);
    } catch (error) {
      return HlsAdFilterAttempt(AdFilterOutcome.unavailable,
          reason: '清单请求失败：$error');
    }
    final text = response.content;
    if (text.isEmpty) {
      return const HlsAdFilterAttempt(AdFilterOutcome.unavailable,
          reason: '清单内容为空');
    }

    if (isMasterPlaylistText(text)) {
      return _filterMaster(text, response.uri, headers);
    }
    if (!isMediaPlaylistText(text)) {
      return const HlsAdFilterAttempt(AdFilterOutcome.noAds,
          reason: '返回的不是媒体播放列表（可能是网页或跳转页）');
    }

    final absolute = absolutizePlaylist(text, response.uri);
    // 直播（无 ENDLIST）与字节范围列表都不碰：剪了必坏。
    if (!hasEndListText(absolute)) {
      return const HlsAdFilterAttempt(AdFilterOutcome.live);
    }
    if (hasByteRangeText(absolute)) {
      return const HlsAdFilterAttempt(AdFilterOutcome.byteRange);
    }

    final analysis = analyzeAdBlocks(absolute);
    if (!analysis.hasAds) {
      return HlsAdFilterAttempt(AdFilterOutcome.noAds,
          reason: analysis.rejected ? '命中过多，判定为整集切片，已放弃' : null);
    }
    final cut = buildCutPlaylist(absolute, analysis);
    if (cut.cuts.isEmpty) {
      return const HlsAdFilterAttempt(AdFilterOutcome.noAds,
          reason: '二次护栏判定没有可安全删除的块');
    }

    final token = _newToken();
    _entries[token] = _Entry.body(
      cut.playlist,
      contentType: 'application/vnd.apple.mpegurl',
    );
    _prune();
    final base = await _ensureServer();
    if (base == null) {
      return const HlsAdFilterAttempt(AdFilterOutcome.unavailable,
          reason: '本地代理端口绑定失败');
    }
    return HlsAdFilterAttempt(
      AdFilterOutcome.filtered,
      result: HlsAdFilterResult(
        url: '$base/p/$token.m3u8',
        fromMaster: false,
        cut: cut,
        analysis: analysis,
      ),
    );
  }

  Future<HlsAdFilterAttempt> _filterMaster(
    String text,
    Uri base,
    Map<String, String> headers,
  ) async {
    final variants = masterVariantUris(text, base);
    if (variants.isEmpty) {
      return const HlsAdFilterAttempt(AdFilterOutcome.noAds,
          reason: '主列表里没有可用的变体');
    }
    final localBase = await _ensureServer();
    if (localBase == null) {
      return const HlsAdFilterAttempt(AdFilterOutcome.unavailable,
          reason: '本地代理端口绑定失败');
    }

    final master = rewriteMasterVariants(text, base, (variant, index) {
      final token = _newToken();
      _entries[token] = _Entry.variant(source: variant, headers: headers);
      return '$localBase/p/$token.m3u8';
    });

    final token = _newToken();
    _entries[token] = _Entry.body(
      absolutizePlaylist(master, base),
      contentType: 'application/vnd.apple.mpegurl',
    );
    _prune();
    return HlsAdFilterAttempt(
      AdFilterOutcome.master,
      result: HlsAdFilterResult(
        url: '$localBase/p/$token.m3u8',
        fromMaster: true,
      ),
      reason: '主列表已转发，裁剪发生在播放器选中的那一档',
    );
  }

  /// 变体请求到来时才拉取并分析该档（播放器选哪档就分析哪档）。
  Future<String?> _resolveVariant(_Entry entry) async {
    final existing = entry.body;
    if (existing != null) return existing;
    final source = entry.source;
    if (source == null) return null;
    final HlsFetchResponse response;
    try {
      response = await _fetch(source, entry.headers, fetchBudget);
    } catch (_) {
      return null;
    }
    final text = response.content;
    if (!isMediaPlaylistText(text)) return null;
    final absolute = absolutizePlaylist(text, response.uri);
    String body = absolute;
    if (hasEndListText(absolute) && !hasByteRangeText(absolute)) {
      final analysis = analyzeAdBlocks(absolute);
      if (analysis.hasAds) {
        final cut = buildCutPlaylist(absolute, analysis);
        if (cut.cuts.isNotEmpty) body = cut.playlist;
      }
    }
    entry.body = body;
    return body;
  }

  Future<String?> _ensureServer() async {
    if (_closed) return null;
    final running = _server;
    if (running != null) return 'http://127.0.0.1:${running.port}';
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.autoCompress = false;
      _server = server;
      server.listen(_handleRequest, onError: (_) {}, cancelOnError: false);
      return 'http://127.0.0.1:${server.port}';
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (!path.startsWith('/p/')) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final token = path.substring(3).replaceFirst(RegExp(r'\.m3u8$'), '');
      final entry = _entries[token];
      if (entry == null || entry.isExpired) {
        if (entry != null) _entries.remove(token);
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('playlist not found');
        await request.response.close();
        return;
      }
      final body =
          entry.body ?? await _resolveVariant(entry).timeout(const Duration(seconds: 10));
      if (body == null) {
        request.response.statusCode = HttpStatus.badGateway;
        request.response.write('playlist unavailable');
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.parse(entry.contentType);
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      // 显式给长度：mpv 对「没有 Content-Length 又走 chunked」的清单不总是友好。
      final bytes = utf8.encode(body);
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    } catch (_) {
      // 响应已发出 / 连接已断开：补一个 500 尽力而为，绝不把异常抛给播放器。
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {
        // 响应已断开：忽略。
      }
    }
  }

  String _newToken() {
    _counter++;
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return '$stamp${_counter.toRadixString(16)}';
  }

  void _prune() {
    _entries.removeWhere((_, entry) => entry.isExpired);
    while (_entries.length > maxEntries) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest);
    }
  }

  static bool _isLoopback(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == 'localhost' ||
        host == '::1' ||
        host.startsWith('127.') ||
        host == '0.0.0.0';
  }

  /// 关闭本地服务并清空缓存（播放器释放时调用）。
  Future<void> shutdown() async {
    _closed = true;
    _entries.clear();
    final server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } catch (_) {
      // 关闭失败不影响退出。
    }
  }
}
